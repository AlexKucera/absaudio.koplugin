-- FFmpeg playback backend for absaudio.koplugin (issue #33 skeleton, #34 pipeline wiring)
--
-- Backend for real in-app audio via libaudio-engine.so (FFmpeg decode + ALSA
-- output), PRD #31 / decision log (Path C, Design 3 decoupled ring buffer).
--
-- Implements the SAME public contract as stub_backend.lua / inkview_backend.lua
-- so it drops into player.create()'s strategy unchanged:
--   ffmpeg_backend.new(opts) → backend instance
--     play(), pause(), resume(), stop(), close()
--     getPosition(), setPosition(sec), getDuration()
--     getCurrentTrack(), getPlaybackSpeed(), setPlaybackSpeed(speed)
--     isFinished(), getState()
--     getLastError()  (slice C: surfaces undecodable-file errors)
--   ffmpeg_backend.is_available() → bool   (guarded FFI probe via audio_ffi; false on dev)
--
-- TWO position modes (dual source — keeps slice B green):
--   * CLOCK mode (no decoder_factory): wall-clock + _advanceTime, identical to
--     stub_backend. Used by the emulator, tests, and slice B's 45 contract tests.
--   * PRODUCER mode (decoder_factory provided): a decode_producer coroutine +
--     output_pump + wake_lock pipeline. Position comes from the producer's PTS
--     via on_position(ms). Used by slice C integration tests and (with the real
--     FFmpeg decoder_factory) on the device.
--
-- opts:
--   track_durations   array    duration of each track in seconds
--   file_paths        array    filesystem path for each track (first used for decode)
--   start_position    number   initial position in seconds (default 0)
--   playback_speed    number   speed multiplier (default 1.0)
--   on_finished       fn       callback(final_position_seconds) when playback reaches end
--   buffer_capacity   number   PCM ring-buffer capacity in bytes (default 1<<20 ≈ 1 MiB)
--   ffi_probe         fn       override is_available() probe for tests
--   --- slice C pipeline opts (when provided, enables PRODUCER mode) ---
--   decoder_factory   fn(path)→decoder|nil,err   [the device seam; tests inject fakes]
--   sink              {write=fn(data,n)}          [ALSA on device; fake in tests]
--   schedule          fn(delay,fn)→cancel_fn      [UIManager:scheduleIn on device]
--   wake_impl         {acquire=fn,release=fn}     [inkview BanSleep on device]
--   chunk_size        number   bytes per pump tick (default 4096)
--
-- Position bookkeeping delegates to slice A's pure library (time_math): the
-- internal position is tracked in milliseconds (the natural FFmpeg PTS unit)
-- and converted to seconds via time_math.ms_to_seconds(), clamped to duration
-- via time_math.clamp(). The pcm_buffer (wrapping ring_buffer) is the mutable
-- storage shared by the producer and pump.
--
-- Transport state machine: "stopped" | "playing" | "paused"

local time_math = require("absaudio/time_math")
local ring_buffer = require("absaudio/ring_buffer")
local pcm_buffer = require("absaudio/pcm_buffer")
local audio_ffi = require("absaudio/audio_ffi")
local decode_producer = require("absaudio/decode_producer")
local output_pump = require("absaudio/output_pump")
local wake_lock = require("absaudio/wake_lock")

------------------------------------------------------------------------
-- Wall-clock resolver: prefer KOReader's high-resolution time module,
-- fall back to os.time() (1-second resolution) for standalone/test use.
------------------------------------------------------------------------
local get_wall_time
do
    local ok, time_mod = pcall(require, "ui/time")
    if ok and time_mod.now then
        get_wall_time = function()
            return time_mod.to_number(time_mod.now())
        end
    else
        get_wall_time = function() return os.time() end
    end
end

local ffmpeg_backend = {}

------------------------------------------------------------------------
-- Whether the FFmpeg backend can run in the current environment.
-- Delegates to audio_ffi (guarded dlopen libaudio-engine + key-symbol check).
-- False on the dev Mac; true on a PocketBook once the toolkit loads.
-- Mockable: ffmpeg_backend._set_probe_override(fn) or pass opts.ffi_probe.
-- @return bool
------------------------------------------------------------------------
function ffmpeg_backend.is_available()
    return audio_ffi.is_available()
end

-- Test-only: override the module-level availability probe (delegates to audio_ffi).
-- @param fn function|nil  nil restores the default guarded probe
function ffmpeg_backend._set_probe_override(fn)
    audio_ffi._set_probe_override(fn)
end

------------------------------------------------------------------------
-- Create a new FFmpeg backend instance.
-- @param opts table  (see module header)
-- @return table  backend instance implementing the full contract
------------------------------------------------------------------------
function ffmpeg_backend.new(opts)
    opts = opts or {}
    local track_durations = opts.track_durations or {}
    local file_paths = opts.file_paths or {}
    local start_position = opts.start_position or 0
    local playback_speed = opts.playback_speed or 1.0
    local on_finished = opts.on_finished
    local buffer_capacity = opts.buffer_capacity or (1024 * 1024)
    local ffi_probe = opts.ffi_probe

    -- Slice C pipeline opts (absent → CLOCK mode, slice B behavior unchanged)
    local decoder_factory = opts.decoder_factory
    local sink = opts.sink
    local schedule = opts.schedule
    local wake_impl = opts.wake_impl
    -- Bytes drained per pump tick. MUST deliver faster than playback consumes
    -- or ALSA underruns. 22050Hz/stereo/S16 = 88,200 bytes/s; at 50ms ticks a
    -- 4096 chunk only delivers 81,920 bytes/s (underfeed → underrun). 8192
    -- delivers up to 163,840 bytes/s (~1.9x headroom) so the ALSA buffer stays
    -- topped up; the sink recovers from any residual underrun via prepare().
    local chunk_size = opts.chunk_size or 8192
    local path = file_paths and file_paths[1]  -- first track (multi-track in a later slice)

    ----------------------------------------------------------------
    -- AUTO-DETECT: when the FFmpeg backend is available (device) AND no
    -- explicit pipeline opts are injected (tests/emulator), build the real
    -- decoder/sink/schedule from audio_device. This is issue #39's wiring:
    -- the proven probe pipeline drops in automatically on the PocketBook.
    -- Off-device (Mac), is_available() is false → CLOCK mode (unchanged).
    ----------------------------------------------------------------
    local probe_fn = ffi_probe or ffmpeg_backend.is_available
    if not decoder_factory and path and probe_fn() then
        local ad_ok, ad = pcall(require, "absaudio/audio_device")
        if ad_ok and ad and ad.create_decoder then
            -- Wrapper sink: the real ALSA sink can't be built until the decoder
            -- opens the file (sample_rate/channels unknown beforehand). The
            -- decoder factory creates the real sink as a side effect once it
            -- discovers the codec params; this placeholder delegates to it.
            local inner_sink = nil
            local real_decoder_factory = function(p)
                local dec, derr = ad.create_decoder(p)
                if dec and not inner_sink then
                    inner_sink = ad.create_alsa_sink({
                        sample_rate = dec:get_sample_rate(),
                        channels = dec:get_channels(),
                    })
                end
                return dec, derr
            end
            decoder_factory = real_decoder_factory
            sink = {
                write = function(data, n)
                    if inner_sink then inner_sink.write(data, n) end
                end,
                close = function()
                    if inner_sink then inner_sink.close() end
                end,
            }
            if not schedule then
                schedule = ad.create_schedule()
            end
        end
    end

    -- Total duration (seconds)
    local total_duration = 0
    for _, d in ipairs(track_durations) do
        total_duration = total_duration + d
    end
    local duration_ms = time_math.seconds_to_ms(total_duration)

    -- Ring buffer (slice A pure index math — kept for getRingBuffer backward compat)
    local rb = ring_buffer.new(buffer_capacity)

    -- PCM buffer (slice C — the mutable storage producer/pump actually use)
    local pcm_buf = pcm_buffer.new(buffer_capacity)

    -- Transport state
    local state = "stopped"
    local position_ms = time_math.seconds_to_ms(start_position)
    local finished = false
    local last_error = nil

    -- Clock tracking: real-time mode (emulator) and manual mode (tests)
    local use_real_time = true   -- false once _advanceTime is called
    local sim_time = 0           -- manual virtual clock (seconds, tests)
    local play_start_sim = 0
    local play_start_real = 0

    -- Producer/pump pipeline state (slice C; only active in PRODUCER mode)
    local producer_active = false      -- true when the pipeline is driving playback
    local producer_position_ms = nil   -- last PTS reported by the producer
    local producer_errored = false     -- distinguishes error-finish from clean-finish
    local pipeline_ended = false       -- idempotent guard for handle_pipeline_end
    local producer = nil
    local pump = nil
    local lock = nil

    ----------------------------------------------------------------
    -- Internal helpers (forward-declared for mutual reference)
    ----------------------------------------------------------------
    local effective_position_ms
    local check_auto_finish
    local rebase_clock
    local start_pipeline
    local stop_pipeline
    local handle_pipeline_end

    -- Clock-based position: position_ms + elapsed*speed. Always used, even in
    -- producer mode — producer_position_ms reflects the decode-AHEAD position
    -- (producer fills a 1 MiB buffer ahead of playback), not the playback
    -- position, making it unsuitable for progress display. The clock is
    -- accurate for forward playback and handles pause/resume via snapshots.
    effective_position_ms = function()
        if state == "playing" then
            local elapsed
            if use_real_time then
                elapsed = get_wall_time() - play_start_real
            else
                elapsed = sim_time - play_start_sim
            end
            local advanced = time_math.seconds_to_ms(elapsed * playback_speed)
            return time_math.clamp(position_ms + advanced, duration_ms)
        else
            return time_math.clamp(position_ms, duration_ms)
        end
    end

    check_auto_finish = function()
        if duration_ms <= 0 then return false end
        local eff = effective_position_ms()
        if eff >= duration_ms then
            state = "stopped"
            position_ms = duration_ms
            finished = true
            if on_finished then
                on_finished(time_math.ms_to_seconds(position_ms))
            end
            return true
        end
        return false
    end

    -- Snapshot the clock baseline so effective_position_ms() measures elapsed from now.
    rebase_clock = function()
        play_start_sim = sim_time
        play_start_real = get_wall_time()
    end

    ----------------------------------------------------------------
    -- Pipeline lifecycle (slice C — only used in PRODUCER mode)
    ----------------------------------------------------------------

    -- Idempotent: tear down pump + producer + wake-lock, then finalize state.
    -- Called from on_drained (natural finish) or on_error (undecodable file).
    handle_pipeline_end = function()
        if pipeline_ended then return end
        pipeline_ended = true
        if pump then pump:stop() end
        if producer then producer:teardown() end
        if lock then lock:release() end
        producer_active = false
        state = "stopped"
        if producer_errored then
            -- Error path: do NOT mark finished, do NOT fire on_finished.
            -- The error is retrievable via getLastError().
        else
            -- Clean finish: mark finished + fire callback.
            finished = true
            position_ms = duration_ms
            if on_finished then
                on_finished(time_math.ms_to_seconds(duration_ms))
            end
        end
    end

    start_pipeline = function()
        pcm_buf:clear()
        pipeline_ended = false
        producer_errored = false
        producer_position_ms = nil
        lock = wake_lock.new({ impl = wake_impl })
        producer = decode_producer.new({
            decoder_factory = decoder_factory,
            path = path,
            buffer = pcm_buf,
            on_position = function(ms) producer_position_ms = ms end,
            on_finished = function() producer_errored = false end,
            on_error = function(err)
                last_error = err
                producer_errored = true
                handle_pipeline_end()
            end,
        })
        pump = output_pump.new({
            buffer = pcm_buf,
            sink = sink,
            producer = producer,
            schedule = schedule,
            chunk_size = chunk_size,
            on_drained = function() handle_pipeline_end() end,
        })
        lock:acquire()
        producer:start()
        pump:start()
    end

    stop_pipeline = function()
        if pump then pump:stop(); pump = nil end   -- cancel ticks BEFORE closing sink
        -- CRITICAL: close the ALSA sink so snd_pcm_close() releases the device.
        -- Without this, every play->stop leaks one PCM handle and the next
        -- snd_pcm_open() returns -16 (EBUSY) -> permanent silence. pause()
        -- does NOT call stop_pipeline (only pump:stop), so the sink stays
        -- open across pause/resume -- correct.
        if sink and sink.close then pcall(sink.close) end
        if producer then producer:teardown(); producer = nil end
        if lock then lock:release(); lock = nil end
        producer_active = false
    end

    ----------------------------------------------------------------
    -- Backend instance
    ----------------------------------------------------------------
    local self = {}

    function self:getState() return state end
    function self:getLastError() return last_error end
    function self:getCurrentTrack()
        if state == "stopped" then return 0 end
        local player_mod = require("absaudio/player")
        local t, _ = player_mod.global_to_track_offset(
            time_math.ms_to_seconds(effective_position_ms()), track_durations)
        return t
    end
    function self:getPlaybackSpeed() return playback_speed end
    function self:setPlaybackSpeed(speed)
        if state == "playing" and not producer_active then
            position_ms = effective_position_ms()
            rebase_clock()
        end
        playback_speed = speed or 1.0
    end
    function self:getPosition()
        return time_math.ms_to_seconds(effective_position_ms())
    end
    function self:setPosition(global_seconds)
        local sec = global_seconds or 0
        if sec < 0 then sec = 0 end
        position_ms = time_math.clamp(time_math.seconds_to_ms(sec), duration_ms)
        if producer_active then
            producer_position_ms = position_ms
        end
        if state == "playing" and not producer_active then
            rebase_clock()
        end
        if not producer_active then
            check_auto_finish()
        end
    end
    function self:getDuration() return total_duration end
    function self:isFinished() return finished end
    function self:getRingBuffer() return rb end
    function self:_advanceTime(delta)
        use_real_time = false
        sim_time = sim_time + delta
        if state == "playing" then check_auto_finish() end
    end

    function self:is_available()
        if ffi_probe then return ffi_probe() end
        return ffmpeg_backend.is_available()
    end

    function self:play()
        if state == "playing" then return end
        -- PRODUCER mode: start the decode/output/wake-lock pipeline
        if decoder_factory and path and not producer_active then
            local ok, err = pcall(start_pipeline)
            if not ok then
                last_error = tostring(err)
                producer_errored = true
                pipeline_ended = true
                if lock then lock:release() end
                producer_active = false
                state = "stopped"
                return
            end
            if producer_errored then
                -- start_pipeline → producer:start() hit on_error (e.g. open fail).
                -- handle_pipeline_end already set state=stopped.
                return
            end
            producer_active = true
            rebase_clock()  -- set play_start_real so clock-mode position advances
            state = "playing"
            return
        end
        -- CLOCK mode (slice B behavior, unchanged)
        position_ms = effective_position_ms()
        rebase_clock()
        state = "playing"
        check_auto_finish()
    end

    function self:pause()
        if state ~= "playing" then return end
        position_ms = effective_position_ms()  -- snapshot clock (ALWAYS, not just clock mode)
        if producer_active and pump then
            pump:stop()  -- pause output drain (producer yields on buffer-full)
        end
        state = "paused"
    end

    function self:resume()
        if state ~= "paused" then return end
        rebase_clock()  -- ALWAYS rebase (not just clock mode)
        if producer_active and pump then
            pump:start()  -- resume output drain
        end
        state = "playing"
        if not producer_active then
            check_auto_finish()
        end
    end

    function self:stop()
        if producer_active then
            stop_pipeline()
        end
        state = "stopped"
        position_ms = 0
    end

    function self:close()
        if producer_active then
            stop_pipeline()
        end
        state = "stopped"
        position_ms = 0
        finished = false
        use_real_time = true
        sim_time = 0
        play_start_sim = 0
        play_start_real = 0
        last_error = nil
    end

    return self
end

return ffmpeg_backend
