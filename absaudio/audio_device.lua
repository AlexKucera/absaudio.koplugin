-- audio_device: real FFmpeg decode + ALSA output glue for the PocketBook
-- (issue #39, audio slice D)
--
-- Builds the real device implementations behind the injectable seams that
-- slice C (issue #34) defined on decode_producer / output_pump / ffmpeg_backend:
--   - create_decoder(path) -> decoder matching decode_producer's injected interface
--   - create_alsa_sink()   -> { write = fn(data, n), close = fn() }
--   - create_schedule()    -> fn(delay_seconds, fn) for output_pump's cadence
--
-- The decode loop and ALSA output body MIRROR the proven reference
-- implementation (audio_probe.run_play_test) exactly, because that is the ONE
-- code path confirmed to produce audible playback on the PB700K3 (see
-- docs/devlog/20260614-issue34-audio-playback-ffmpeg-alsa-audible-success_log.md).
-- Any deviation here risks re-introducing a dead-end the probe already closed
-- (tts_sm virtual sink, wrong sample_rate offset, FLTP not resampled, etc.).
--
-- Cdefs and the lib handle come from audio_ffi (guarded). All FFmpeg/ALSA calls
-- are pcall-guarded: a native error surfaces as a Lua (nil, err) return, never a
-- hard crash. Native SIGSEGV from a bad pointer is NOT catchable by pcall, so
-- the decode loop only touches fields at the on-device-verified offsets.
--
-- Public API:
--   audio_device.create_decoder(path) -> decoder | nil, err
--     decoder:read_frame() -> { pcm = <string>, pts_ms = <number> } | nil(EOF) | nil, err
--     decoder:close()
--   audio_device.create_alsa_sink(opts) -> sink | nil, err
--     sink.write(data_string, n)   -- called by output_pump
--     sink.close()
--   audio_device.create_schedule() -> fn(delay_seconds, fn) -> cancel_fn

local audio_ffi = require("absaudio/audio_ffi")
local time_math = require("absaudio/time_math")
local logger  -- lazy: pcall-guarded so off-device tests don't crash
do
    local ok, l = pcall(require, "logger")
    logger = ok and l or {
        warn = function(...) print("[WARN] " .. string.format(...)) end,
        info = function(...) print("[INFO] " .. string.format(...)) end,
    }
end

local audio_device = {}

------------------------------------------------------------------------
-- FFmpeg / ALSA constants (confirmed on-device)
------------------------------------------------------------------------
local AVMEDIA_TYPE_AUDIO = 1
local AV_SAMPLE_FMT_FLTP = 8   -- planar float (AAC native decode format)
local AV_SAMPLE_FMT_S16  = 1   -- interleaved signed 16-bit (ALSA target)
local AV_NOPTS_VALUE     = 0x8000000000000000ULL  -- int64 sentinel: no PTS

-- ALSA
local SND_PCM_STREAM_PLAYBACK  = 0
local SND_PCM_FORMAT_S16_LE    = 2
local SND_PCM_ACCESS_RW_INTERLEAVED = 3

-- Confirmed real hardware device (tts_sm is a virtual sink that swallows audio).
-- First entry is the proven device; the rest are fallbacks (probe tried these).
-- PocketBook runs an `alsaloop` daemon at boot that grabs the hardware
-- audio device (hw:0,0) exclusively and bridges it: it captures from the
-- ALSA Loopback card (card 1) device 1, and plays to the speaker. User apps
-- are meant to write to the Loopback device 0 playback side — the cross-
-- connected pair feeds alsaloop's capture. Writing to plughw:0,0 directly
-- fails with EBUSY because alsaloop holds it.
local ALSA_DEVICES = {
    "plughw:1,0",       -- Loopback card 1, dev 0 (feeds alsaloop capture from dev 1)
    "hw:1,0",           -- same, raw
    "plughw:0,0",      -- direct hardware (only if alsaloop is killed)
    "hw:0,0",
    "default",
}
local ALSA_LATENCY_US = 1000000  -- 1.0s. Bigger buffer = survives e-ink full-flash
-- blockages (~0.5s) without underrunning. Audiobook latency is irrelevant, so
-- favor resilience over responsiveness. (Was 500000 = 0.5s; flash caused pause.)

------------------------------------------------------------------------
-- Obtain the FFI module + lib handle (guarded). Returns (ffi, lib) or (nil, nil).
------------------------------------------------------------------------
local function ffi_and_lib()
    local lib = audio_ffi.get_lib()
    if not lib then return nil, nil end
    local ok, ffi = pcall(require, "ffi")
    if not ok then return nil, nil end
    return ffi, lib
end

------------------------------------------------------------------------
-- Create a real FFmpeg decoder for an audio file.
--
-- Mirrors audio_probe.run_play_test sections 1-3 (open file, open codec, swr
-- setup). Returns a decoder object implementing the injected-decoder contract:
--   read_frame() -> { pcm = string, pts_ms = number } | nil(EOF) | nil, err
--   close()
-- Each read_frame pulls one decoded audio frame, resamples FLTP->S16, and
-- returns the interleaved S16 bytes + the frame's PTS in milliseconds.
--
-- @param path string  filesystem path to the M4B/audio file
-- @return decoder table | nil, err
------------------------------------------------------------------------
function audio_device.create_decoder(path)
    local ffi, lib = ffi_and_lib()
    if not ffi then return nil, "audio_device: FFmpeg unavailable (lib not loaded)" end

    -- Everything below is wrapped so a Lua error during setup surfaces as
    -- (nil, err) instead of escaping. A native SIGSEGV is NOT catchable, so the
    -- code only touches on-device-verified offsets.
    local ok_setup, ctx_or_err = pcall(function()
        -- ---- 1. Open the container ----
        local fmt_ctx_ptr = ffi.new("struct AVFormatContext*[1]")
        local cpath = ffi.new("const char[?]", #path + 1, path)
        local ret = lib.avformat_open_input(fmt_ctx_ptr, cpath, nil, nil)
        if ret ~= 0 then
            return nil, "avformat_open_input failed: " .. tonumber(ret)
        end
        local fmt_ctx = fmt_ctx_ptr[0]

        -- find_stream_info probes the file (can take 10-30s on M4B)
        lib.avformat_find_stream_info(fmt_ctx, nil)

        local stream_idx = lib.av_find_best_stream(fmt_ctx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        if stream_idx < 0 then
            lib.avformat_close_input(fmt_ctx_ptr)
            return nil, "no audio stream (av_find_best_stream=" .. tonumber(stream_idx) .. ")"
        end

        -- ---- Read stream params via the verified AVStream/AVCodecParameters offsets ----
        local fmt_cast = ffi.cast("struct AVFormatContext*", fmt_ctx)
        local stream = fmt_cast.streams[stream_idx]
        local st = ffi.cast("struct AVStream*", stream)
        local codecpar = st.codecpar
        local time_base = { num = st.time_base.num, den = st.time_base.den }

        -- codecpar fields (on-device-verified offsets)
        local cp = ffi.cast("uint8_t*", codecpar)
        local in_sample_rate = tonumber(ffi.cast("int32_t*", cp + 108)[0])
        local in_channels    = tonumber(ffi.cast("int32_t*", cp + 104)[0])
        local in_ch_layout   = tonumber(ffi.cast("int64_t*", cp + 96)[0]) or 0
        if not in_sample_rate or in_sample_rate <= 0 or not in_channels or in_channels <= 0 then
            lib.avformat_close_input(fmt_ctx_ptr)
            return nil, "invalid codecpar (rate=" .. tostring(in_sample_rate)
                .. " ch=" .. tostring(in_channels) .. ")"
        end

        -- ---- 2. Open the codec ----
        local codec_ptr = ffi.new("const struct AVCodec*[1]")
        lib.av_find_best_stream(fmt_ctx, AVMEDIA_TYPE_AUDIO, -1, -1, codec_ptr, 0)
        local codec = codec_ptr[0]
        local ctx = lib.avcodec_alloc_context3(codec)
        lib.avcodec_parameters_to_context(ctx, codecpar)
        ret = lib.avcodec_open2(ctx, codec, nil)
        if ret ~= 0 then
            lib.avformat_close_input(fmt_ctx_ptr)
            return nil, "avcodec_open2 failed: " .. tonumber(ret)
        end

        -- ---- 3. Setup swresample: FLTP -> S16 interleaved ----
        local swr = lib.swr_alloc()
        swr = lib.swr_alloc_set_opts(swr,
            in_ch_layout, AV_SAMPLE_FMT_S16, in_sample_rate,   -- output
            in_ch_layout, AV_SAMPLE_FMT_FLTP, in_sample_rate,  -- input
            0, nil)
        ret = lib.swr_init(swr)
        if ret ~= 0 then
            lib.swr_free(ffi.new("struct SwrContext*[1]", { swr }))
            lib.avformat_close_input(fmt_ctx_ptr)
            return nil, "swr_init failed: " .. tonumber(ret)
        end

        -- ---- Packet + frame alloc ----
        local pkt = lib.av_packet_alloc()
        local frame = lib.av_frame_alloc()

        -- Per-frame S16 output buffer. out_count is in FRAMES (samples/channel)
        -- per swr_convert's contract, so the buffer must hold frames*channels*2
        -- bytes. AAC frame_size ~1024; 4096 frames headroom covers resample growth.
        local max_frames = 4096
        local out_buf = ffi.new("int16_t[?]", max_frames * (in_channels or 2) * 2)
        local out_ptrs = ffi.new("uint8_t*[1]")
        out_ptrs[0] = ffi.cast("uint8_t*", out_buf)
        local in_ptrs = ffi.new("const uint8_t*[2]")

        local d_table = {
            _lib = lib,
            _fmt_ctx_ptr = fmt_ctx_ptr,
            _fmt_ctx = fmt_ctx,
            _ctx = ctx,
            _swr = swr,
            _pkt = pkt,
            _frame = frame,
            _out_buf = out_buf,
            _out_ptrs = out_ptrs,
            _in_ptrs = in_ptrs,
            _max_frames = max_frames,
            _time_base = time_base,
            _channels = in_channels,  -- read_frame uses this for FLTP plane count
            _sample_rate = in_sample_rate,  -- ALSA sink needs this
            _samples_decoded = 0,  -- sample-count position tracking (pts offset is wrong)
            _closed = false,
        }
        return d_table
    end)
    if not ok_setup then
        return nil, "decoder setup error: " .. tostring(ctx_or_err)
    end
    -- ctx_or_err is the (nil, err) pair from inside, or the ctx table
    if type(ctx_or_err) ~= "table" then
        -- setup returned (nil, errstring); ctx_or_err is the string (or nil)
        return nil, ctx_or_err or "decoder setup failed"
    end
    local d = ctx_or_err
    local decoder_channels = d._channels or 2  -- capture before read_frame closes over it

    --------------------------------------------------------------------
    -- decoder:get_sample_rate() / get_channels() — for ALSA sink config
    --------------------------------------------------------------------
    function d:get_sample_rate() return self._sample_rate or 44100 end
    function d:get_channels() return self._channels or 2 end

    --------------------------------------------------------------------
    -- decoder:read_frame() -> { pcm, pts_ms } | nil(EOF) | nil, err
    -- Mirrors probe section 5 inner loop (av_read_frame -> send_packet ->
    -- receive_frame -> swr_convert). Resamples one decoded frame FLTP->S16.
    --------------------------------------------------------------------
    function d:read_frame()
        if self._closed then return nil, "decoder closed" end
        local lib = self._lib
        local frame = self._frame
        local pkt = self._pkt

        -- Loop until we decode one audio frame (skips non-audio / non-decodable
        -- packets, matching the probe).
        while true do
            local ret = lib.av_read_frame(self._fmt_ctx, pkt)
            if ret < 0 then
                -- negative => EOF or read error; treat as EOF (clean stop)
                return nil
            end
            lib.avcodec_send_packet(self._ctx, pkt)
            lib.av_packet_unref(pkt)
            ret = lib.avcodec_receive_frame(self._ctx, frame)
            if ret == 0 then
                local nb = frame.nb_samples
                if nb <= 0 then
                    lib.av_frame_unref(frame)
                    -- empty frame, keep reading
                else
                    -- FLTP planar: data[0]=L, data[1]=R
                    self._in_ptrs[0] = ffi.cast("uint8_t*", frame.data[0])
                    if decoder_channels >= 2 then
                        self._in_ptrs[1] = ffi.cast("uint8_t*", frame.data[1])
                    else
                        self._in_ptrs[1] = self._in_ptrs[0]
                    end
                    local out_count = self._max_frames
                    local nsamp = lib.swr_convert(self._swr, self._out_ptrs, out_count,
                                                  self._in_ptrs, nb)
                    -- Read PTS BEFORE av_frame_unref (unref resets frame fields).
                    -- Primary: try frame.pts (accurate, handles seeking natively).
                    -- AVFrame.pts offset is unconfirmed (probe showed offsetof=160
                    -- vs commented 192), so pts reads as 0 for every frame.
                    local pts_ms = 0
                    if frame.pts ~= AV_NOPTS_VALUE then
                        local pts = tonumber(frame.pts) or 0
                        if pts > 0 then  -- only trust non-zero pts
                            pts_ms = time_math.to_ms(pts, self._time_base)
                        end
                    end
                    -- Fallback: sample-count accumulation. Depends only on
                    -- nb_samples@112 + sample_rate (both verified on-device) →
                    -- reliable monotonic position for forward playback.
                    if pts_ms == 0 then
                        pts_ms = math.floor(self._samples_decoded * 1000 /
                            (self._sample_rate or 22050))
                    end
                    lib.av_frame_unref(frame)
                    if nsamp and nsamp > 0 then
                        -- Interleaved S16: nsamp is FRAMES (samples/channel)
                        -- from swr_convert; byte length = frames * channels * 2.
                        local channels = self._channels or 2
                        local byte_len = tonumber(nsamp) * channels * 2
                        -- Accumulate output samples for position tracking.
                        -- Done AFTER computing pts_ms (pts = start of frame).
                        self._samples_decoded = self._samples_decoded + tonumber(nsamp)
                        local pcm = ffi.string(self._out_ptrs[0], byte_len)
                        return { pcm = pcm, pts_ms = pts_ms }
                    end
                    -- nsamp == 0: no output yet (swr buffering), keep reading
                end
            else
                -- receive_frame < 0: need more packets (EAGAIN) or end; keep reading
            end
        end
    end

    --------------------------------------------------------------------
    -- decoder:close()  -- free everything (idempotent)
    --------------------------------------------------------------------
    function d:close()
        if self._closed then return end
        self._closed = true
        local lib = self._lib
        pcall(function()
            if self._frame then
                lib.av_frame_free(ffi.new("struct AVFrame*[1]", { self._frame }))
                self._frame = nil
            end
            if self._pkt then
                lib.av_packet_free(ffi.new("struct AVPacket*[1]", { self._pkt }))
                self._pkt = nil
            end
            if self._swr then
                lib.swr_free(ffi.new("struct SwrContext*[1]", { self._swr }))
                self._swr = nil
            end
            if self._ctx then
                lib.avcodec_free_context(ffi.new("struct AVCodecContext*[1]", { self._ctx }))
                self._ctx = nil
            end
            if self._fmt_ctx_ptr then
                lib.avformat_close_input(self._fmt_ctx_ptr)
                self._fmt_ctx_ptr = nil
            end
        end)
    end

    --------------------------------------------------------------------
    -- decoder:get_duration_ms() -> number
    -- Reads AVFormatContext.duration (AV_TIME_BASE=1e6 microseconds) at offset 72.
    -- Offset is FFmpeg 6.0 standard layout (UNVERIFIED on PB700K3 — device must confirm).
    -- Returns 0 if duration is unavailable.
    --------------------------------------------------------------------
    function d:get_duration_ms()
        local fmt = ffi.cast("struct AVFormatContext*", self._fmt_ctx)
        local dur_us = tonumber(fmt.duration) or 0
        if dur_us and dur_us > 0 then
            return math.floor(dur_us / 1000)  -- us -> ms
        end
        return 0
    end

    return d
end

-- (in_channels is captured per-decoder as `decoder_channels` at creation;
-- the FLTP plane count is constant for the whole file.)

------------------------------------------------------------------------
-- Create a real ALSA output sink.
--
-- Mirrors audio_probe.run_play_test section 4: on first write, open the proven
-- "plughw:0,0" device (with fallbacks) and configure S16_LE / RW_INTERLEAVED.
-- Each write pushes interleaved S16 samples via snd_pcm_writei.
--
-- @param opts table  { sample_rate = number, channels = number }  [REQUIRED]
-- @return sink table | nil, err
------------------------------------------------------------------------
function audio_device.create_alsa_sink(opts)
    opts = opts or {}
    local sample_rate = opts.sample_rate
    local channels = opts.channels
    if not sample_rate or not channels then
        return nil, "create_alsa_sink: sample_rate and channels required"
    end

    local ffi, lib = ffi_and_lib()
    if not ffi then return nil, "audio_device: ALSA unavailable (lib not loaded)" end

    local sink = {
        _lib = lib,
        _pcm = nil,           -- snd_pcm_t* (opened lazily on first write)
        _opened = false,
        _failed = false,
        _device = nil,
        _sample_rate = sample_rate,
        _channels = channels,
    }


    -- Open the ALSA device lazily on first write so a sink can be created before
    -- the codec params are finalized. Tries the proven device list in order.
    local function open_pcm()
        if sink._opened or sink._pcm then return true end
        local ok, err = pcall(function()
            for _, devname in ipairs(ALSA_DEVICES) do
                local pcm_ptr = ffi.new("snd_pcm_t*[1]")
                local ret = lib.snd_pcm_open(pcm_ptr, devname, SND_PCM_STREAM_PLAYBACK, 0)
                if ret < 0 then
                    local errstr = lib.snd_strerror and ffi.string(lib.snd_strerror(ret)) or tostring(ret)
                    logger.warn("[absaudio] ALSA open('%s') failed: %s", devname, errstr)
                else
                    local pcm = pcm_ptr[0]
                    ret = lib.snd_pcm_set_params(pcm,
                        SND_PCM_FORMAT_S16_LE, SND_PCM_ACCESS_RW_INTERLEAVED,
                        sink._channels, sink._sample_rate, 1, ALSA_LATENCY_US)
                    if ret < 0 then
                        logger.warn("[absaudio] ALSA set_params('%s') failed: %d", devname, ret)
                        lib.snd_pcm_close(pcm)
                    else
                        sink._pcm = pcm
                        sink._device = devname
                        sink._opened = true
                        logger.info("[absaudio] ALSA opened '%s' (ch=%d rate=%d)", devname, sink._channels, sink._sample_rate)
                        return
                    end
                end
            end
        end)
        if not ok then
            sink._failed = true
            logger.warn("[absaudio] open_pcm pcall threw: %s", tostring(err))
            return false, err
        end
        if not sink._opened then
            sink._failed = true
            return false, "all ALSA devices failed to open"
        end
        return true
    end

    -- Lazy open is exposed so callers (ffmpeg_backend.play) can fail fast.
    function sink.open()
        return open_pcm()
    end

    --------------------------------------------------------------------
    -- sink.write(data_string, n)  -- called by output_pump
    -- n is the byte count; frames = n / (channels*2) (S16). Idempotent on close.
    --------------------------------------------------------------------
    function sink.write(data, n)
        if not sink._opened and not sink._failed then sink.open() end
        if not sink._pcm or sink._failed then return end
        local pcm = sink._pcm
        -- n is byte count; snd_pcm_writei wants FRAMES (samples/channel) =
        -- bytes / (channels * 2). Dividing by 2 (mono math) made ALSA read 2x
        -- the buffer for stereo → scratchy audio (fixed).
        local channels = sink._channels or 2
        local frames = math.floor((n or #data) / (channels * 2))
        if frames <= 0 then return end
        -- Write with ERROR RECOVERY. Two recoverable errors:
        --   -EPIPE (-32): underrun — stream stuck; prepare() to reset.
        --   -ESTRPIPE (-86): stream suspended (Loopback bridge idle/system
        --     suspend). Recovery: snd_pcm_resume() first (clean), fall back
        --     to snd_pcm_prepare() if not supported (-ENOSYS).
        -- NOTE: ESTRPIPE is errno 86 on Linux, NOT 77 (the original -77
        -- check never matched, causing the Loopback device's suspend at ~29s
        -- to hit FATAL-giveup and kill playback permanently).
        for attempt = 1, 3 do
            local wret
            local ok = pcall(function()
                wret = tonumber(lib.snd_pcm_writei(pcm, data, frames)) or -999
            end)
            if not ok then return end
            if wret >= 0 then return end  -- success
            if wret == -11 then
                -- EAGAIN: retry without recovery
            elseif wret == -86 then
                -- ESTRPIPE: try resume first, fall back to prepare
                local rret = -999
                if lib.snd_pcm_resume then
                    pcall(function() rret = tonumber(lib.snd_pcm_resume(pcm)) or -999 end)
                end
                if rret < 0 then
                    -- resume not supported; fall back to prepare
                    local pret = -999
                    pcall(function() pret = tonumber(lib.snd_pcm_prepare(pcm)) or -999 end)
                    if pret < 0 then return end
                end
            elseif wret == -32 then
                -- EPIPE: underrun recovery
                local pret = -999
                pcall(function() pret = tonumber(lib.snd_pcm_prepare(pcm)) or -999 end)
                if pret < 0 then return end
            else
                return  -- unrecoverable error
            end
        end
    end

    function sink.close()
        if not sink._opened then return end
        pcall(function()
            if sink._pcm then
                lib.snd_pcm_drain(sink._pcm)
                lib.snd_pcm_close(sink._pcm)
                sink._pcm = nil
            end
        end)
        sink._opened = false
    end

    return sink
end

------------------------------------------------------------------------
-- Create a schedule function backed by KOReader's UIManager:scheduleIn.
-- output_pump uses this for its ~50ms drain cadence on the device. Falls back
-- to a no-op cancel if UIManager is unavailable (tests inject their own).
-- @return fn(delay_seconds, fn) -> cancel_fn
------------------------------------------------------------------------
function audio_device.create_schedule()
    return function(delay, callback)
        local ok, UIManager = pcall(require, "ui/uimanager")
        if ok and UIManager.scheduleIn then
            return UIManager:scheduleIn(delay, callback)
        end
        return function() end  -- no-op cancel
    end
end

return audio_device
