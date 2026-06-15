-- Audio capability probe v5 — reverse-engineer the position-read API (de-risk path B).
--
-- GOAL: determine whether GetAudioPlayingInfo() exposes a clean, readable
-- position+duration+state struct that a live-sync audio backend (path B) could
-- poll. Also confirm the read-only state getters (hw_is_audio_book_playing, etc.).
--
-- TECHNIQUE:
--   * Call GetAudioPlayingInfo() TWICE with a ~1.5s gap. The field whose value
--     CHANGES between calls is the live playback position. We know this book's
--     duration (~6425.24 s) as a fingerprint to identify the duration field.
--   * Dump the struct interpreted four ways (int32 / int64 / float / double).
--   * Only call READ-ONLY getters. Never call transport fns (hw_mp_setstate etc.)
--     — this probe must not alter playback.
--
-- SAFETY:
--   * Unknown C signatures → for GetAudioPlayingInfo we declare it as
--     (void* buf) -> void*, pass a zeroed buffer (covers the "fills out-struct"
--     pattern), AND range-check the return value against /proc/self/maps before
--     dereferencing (covers the "returns internal ptr" pattern without crashing
--     on a garbage return).
--   * Emits no sound; never opens hw:0.
--
-- RUN INSTRUCTIONS (IMPORTANT):
--   1. Start the NATIVE PocketBook audiobook player and PLAY your downloaded
--      book (so live state exists to read).
--   2. Then run this probe from the absaudio menu.
local audio_probe = {}
audio_probe.REPORT_PATH = "/mnt/ext1/absaudio_probe_report.txt"

function audio_probe.run()
    local lines = {}
    local function out(s) table.insert(lines, tostring(s)) end
    local function section(t) out(""); out("==== " .. t .. " ====") end
    local function sh(cmd)
        local h = io.popen(cmd .. " 2>/dev/null")
        if not h then return "" end
        local r = h:read("*a") or ""; h:close()
        return (r:gsub("^%s+", ""):gsub("%s+$", ""))
    end

    out("absaudio audio capability probe v5 (position-API reverse engineering)")
    out("run: " .. os.date("%Y-%m-%d %H:%M:%S"))

    local ffi_ok, ffi = pcall(require, "ffi")
    local lib  -- libinkview handle
    if ffi_ok then
        pcall(ffi.cdef, [[
            void *GetAudioPlayingInfo(void *out_buf);
            void *GetAudioOutput(void);
            int  get_audio_status(void);
            int  hw_is_audio_book_playing(void);
            int  hw_is_player_playing(void);
            int  hw_is_reader_player_playing(void);
            int  hw_is_browser_playing(void);
            int  hw_is_screen_playing(void);
            int  hw_mp_getvolume(void);
            int  GetVolume(void);
            int  IsPlayingMP3(void);
            void *dlopen(const char*, int);
            void *dlsym(void*, const char*);
            char *dlerror(void);
        ]])
        local ok, l = pcall(ffi.load, "inkview")
        if ok then lib = l; out("libinkview loaded") else out("libinkview load FAILED: "..tostring(l)) end
    else
        out("require('ffi') FAILED: "..tostring(ffi))
    end

    -- Pointer NULL test (LuaJIT NULL cdata is not == nil reliably).
    local function is_null(p)
        if p == nil then return true end
        local ok, n = pcall(function() return tonumber(ffi.cast("uintptr_t", p)) end)
        return (not ok) or n == 0
    end

    -- Build mapped-memory range list from /proc/self/maps to validate pointers.
    local maps = {}
    local mf = io.open("/proc/self/maps", "r")
    if mf then
        for line in mf:lines() do
            local a, b = line:match("^(%x+)-(%x+)%s")
            if a and b then maps[#maps+1] = { tonumber(a, 16), tonumber(b, 16) } end
        end
        mf:close()
    end
    local function in_range(p)
        if is_null(p) then return false end
        local ok, n = pcall(function() return tonumber(ffi.cast("uintptr_t", p)) end)
        if not ok then return false end
        for _, r in ipairs(maps) do if n >= r[1] and n < r[2] then return true end end
        return false
    end

    -- =====================================================================
    section("1. READ-ONLY STATE GETTERS (safe: int (void))")
    -- =====================================================================
    if lib then
        local function trycall(name)
            -- lib[name] itself can throw 'undefined symbol' for symbols we
            -- declared in cdef but that aren't exported by THIS firmware build
            -- (e.g. IsPlayingMP3). Wrap the access too, not just the call.
            local ok_lookup, fn = pcall(function() return lib[name] end)
            if not ok_lookup or not fn then
                out(string.format("  %-30s <not exported>", name)); return
            end
            local ok, v = pcall(function() return fn() end)
            if ok then out(string.format("  %-30s = %s", name, tostring(v)))
            else out(string.format("  %-30s <call failed: %s>", name, tostring(v))) end
        end
        for _, n in ipairs({"get_audio_status", "hw_is_audio_book_playing",
                            "hw_is_player_playing", "hw_is_reader_player_playing",
                            "hw_is_browser_playing", "hw_is_screen_playing",
                            "hw_mp_getvolume", "GetVolume", "IsPlayingMP3"}) do trycall(n) end
    else
        out("(libinkview not loaded — skipping)")
    end

    -- =====================================================================
    section("2. GetAudioPlayingInfo — struct dump (PASS 1)")
    -- =====================================================================
    -- Fingerprint: this book duration ~6425.24 s (~6425240 ms).
    local DUR_S, DUR_MS = 6425, 6425240
    local function near(v, target, tol) return type(v)=="number" and math.abs(v-target) <= tol end

    local function dump_struct(label, base_ptr, nbytes)
        if not (ffi_ok and base_ptr) or is_null(base_ptr) then out(label..": <null>"); return end
        if not in_range(base_ptr) then out(label..": <pointer outside mapped range; not dereferencing>"); return end
        out(string.format("%s (ptr=%s, %d bytes):", label,
            string.format("0x%x", tonumber(ffi.cast("uintptr_t", base_ptr)) or 0), nbytes))
        local n32 = math.floor(nbytes/4)
        local p32 = ffi.cast("int32_t*", base_ptr)
        local pf  = ffi.cast("float*", base_ptr)
        local p64 = ffi.cast("int64_t*", base_ptr)
        local pd  = ffi.cast("double*", base_ptr)
        for i = 0, n32 - 1 do
            local iv = tonumber(p32[i])
            local fv = tonumber(pf[i])
            local tags = {}
            if near(iv, DUR_S, 2) or near(iv, DUR_MS, 2000) then tags[#tags+1]="DUR?" end
            if near(fv, DUR_S, 2) then tags[#tags+1]="DUR(f)?" end
            if (iv == 0 or iv == 2 or iv == 3) then tags[#tags+1]="state?" end
            local tag = (#tags > 0) and ("  <" .. table.concat(tags, ",") .. ">") or ""
            out(string.format("  [%2d] i32=%-12d f=%.3f%s", i, iv, fv, tag))
        end
        -- int64 / double view (8-byte aligned)
        for i = 0, math.floor(nbytes/8) - 1 do
            local i64 = tonumber(p64[i])
            local dv  = tonumber(pd[i])
            local tags = {}
            if near(i64, DUR_MS, 2000) then tags[#tags+1]="DUR(ms)?" end
            if near(dv, DUR_S, 0.5) then tags[#tags+1]="DUR(d)?" end
            if (#tags > 0) or (i < 4) then
                local tag2 = (#tags > 0) and ("  <" .. table.concat(tags, ",") .. ">") or ""
                out(string.format("  [%2d] i64=%-14d d=%.5f%s", i, i64, dv, tag2))
            end
        end
    end

    local buf1, ret1, ok1, err1
    if ffi_ok and lib and lib.GetAudioPlayingInfo then
        buf1 = ffi.new("unsigned char[256]")
        ok1, err1 = pcall(function() ret1 = lib.GetAudioPlayingInfo(buf1) end)
        if not ok1 then out("GetAudioPlayingInfo call FAILED: "..tostring(err1))
        else
            out("PASS 1 returned without error.")
            dump_struct("  [caller buffer]", ffi.cast("void*", buf1), 256)
            dump_struct("  [return value]",  ret1, 128)
        end
    else
        out("GetAudioPlayingInfo not available")
    end

    -- =====================================================================
    section("3. GetAudioPlayingInfo — PASS 2 (1.5s later; changed field = POSITION)")
    -- =====================================================================
    -- Sleep via a busy loop (no socket/ffi.sleep dependency); ~1.5s.
    local t0 = os.time()
    while os.difftime(os.time(), t0) < 1.5 do end

    if ffi_ok and lib and lib.GetAudioPlayingInfo and ok1 then
        local buf2 = ffi.new("unsigned char[256]")
        local ret2
        local ok2 = pcall(function() ret2 = lib.GetAudioPlayingInfo(buf2) end)
        if ok2 then
            out("PASS 2 (1.5s later). Diffing caller-buffer int32 fields:")
            if in_range(ffi.cast("void*", buf1)) and in_range(ffi.cast("void*", buf2)) then
                local p1 = ffi.cast("int32_t*", buf1)
                local p2 = ffi.cast("int32_t*", buf2)
                local pf1 = ffi.cast("float*", buf1)
                local pf2 = ffi.cast("float*", buf2)
                local pd1 = ffi.cast("double*", buf1)
                local pd2 = ffi.cast("double*", buf2)
                for i = 0, 63 do
                    local a, b = tonumber(p1[i]), tonumber(p2[i])
                    if a ~= b then
                        local af, bf = tonumber(pf1[i]), tonumber(pf2[i])
                        out(string.format("  [%2d] CHANGED  i32: %d -> %d (Δ=%d)   f: %.3f -> %.3f",
                            i, a, b, b-a, af, bf))
                    end
                end
                for i = 0, 31 do
                    local a, b = tonumber(pd1[i]), tonumber(pd2[i])
                    if math.abs((a or 0)-(b or 0)) > 0.001 then
                        out(string.format("  [d%2d] CHANGED  d: %.4f -> %.4f", i, a, b))
                    end
                end
                out("  (A field that advances by ~1-2 over the 1.5s gap = live position in seconds.)")
            else
                out("  (buffers not in mapped range — skipping diff)")
            end
            dump_struct("  [return value pass 2]", ret2, 128)
        else
            out("PASS 2 failed")
        end
    end

    -- =====================================================================
    section("4. GetAudioOutput")
    -- =====================================================================
    if ffi_ok and lib and lib.GetAudioOutput then
        local ok, ao = pcall(function() return lib.GetAudioOutput() end)
        if ok and in_range(ao) then
            local s = ""
            pcall(function() s = ffi.string(ffi.cast("char*", ao)) end)
            out("GetAudioOutput (as string): "..tostring(s))
            dump_struct("GetAudioOutput", ao, 64)
        else
            out("GetAudioOutput: "..(ok and "<null/out-of-range>" or "<failed>"))
        end
    end

    -- =====================================================================
    section("5. INTERPRETATION NOTES")
    -- =====================================================================
    out("DURATION fingerprint for this book: ~6425.24 s (6425240 ms).")
    out("Any int32/float field ≈6425 or int ≈6425240 = likely DURATION.")
    out("The field that changes between PASS 1 and PASS 2 (Δ≈1-2 over 1.5s) = POSITION (seconds).")
    out("A field ==2 likely = MP_PLAYING state; ==0 = MP_STOPPED.")
    out("If a clean position+duration+state emerge here, path B (in-app hw_mp backend")
    out("with live ABS playhead sync) is viable without reverse-engineering more.")

    local report = table.concat(lines, "\n") .. "\n"
    local rf = io.open(audio_probe.REPORT_PATH, "w")
    if rf then rf:write(report); rf:close() end
    return report
end

-- =====================================================================
-- CAPABILITY SCAN for the FFmpeg+ALSA backend (issue #34 slice C, device)
--
-- GOAL: before writing decode/ALSA code that calls FFmpeg symbols, confirm
-- exactly which .so each symbol loads from. This is pure symbol-resolution
-- detection — it NEVER calls a function that touches hardware (no decode,
-- no snd_pcm_open). Every lookup is pcall-guarded so a missing/undefined
-- symbol reports <not exported> instead of crashing the plugin.
--
-- Run from the absaudio menu ("Audio diagnostics (probe)"); reads the same
-- report path. The summary shows which of the DECODE/SWR/ALSA symbol groups
-- fully resolved, and from which library. This determines the cdef strategy
-- for audio_ffi.lua on this device.
-- =====================================================================

-- Symbol groups the decode producer + output pump plan to call. Each must
-- resolve from SOME loaded .so for that pipeline stage to work on-device.
local CAP_DECODE = {
    -- container
    "avformat_open_input", "avformat_find_stream_info", "av_read_frame",
    "avformat_close_input", "av_seek_frame",
    -- stream + codec selection
    "av_find_best_stream", "avcodec_find_decoder", "avcodec_open2",
    "avcodec_close", "avcodec_free_context",
    -- send/receive
    "avcodec_send_packet", "avcodec_receive_frame",
    "av_packet_alloc", "av_packet_unref", "av_packet_free",
    "av_frame_alloc", "av_frame_free",
}
local CAP_SWR = {
    "swr_alloc", "swr_alloc_set_opts", "swr_init", "swr_convert", "swr_free",
    "swr_set_opt", "av_opt_set_int", "av_opt_set_sample_fmt",
    "av_get_bytes_per_sample", "av_samples_get_buffer_size",
}
local CAP_ALSA_RAW = {
    -- raw snd_pcm_* on tts_sm
    "snd_pcm_open", "snd_pcm_set_params", "snd_pcm_writei",
    "snd_pcm_drain", "snd_pcm_close", "snd_pcm_recover",
    "snd_strerror",
}
local CAP_AUDIOENGINE = {
    -- libaudio-engine.so bundled output helpers (amplifier-aware?)
    "open_alsa", "open_alsa_ex", "push_output_buffer", "get_output_buffer",
    "alsa_output_working", "init_alsa_output", "deinit_alsa_output",
    "pause_alsa",
}

-- Candidate .so files to probe, in load order. FFmpeg symbols may live in
-- either libaudio-engine.so (re-exported) or libavcodec.so.60 / libavformat.*
local CANDIDATE_LIBS = {
    { name = "audio-engine",   desc = "libaudio-engine.so (PB bundled toolkit)" },
    { name = "avcodec",        desc = "libavcodec.so.60 (FFmpeg 6.0 codecs)" },
    { name = "avformat",       desc = "libavformat.so (FFmpeg container)" },
    { name = "avutil",         desc = "libavutil.so (FFmpeg utils)" },
    { name = "swresample",     desc = "libswresample.so (FFmpeg resample)" },
    { name = "asound",         desc = "libasound.so (ALSA)" },
}

-- Resolve a symbol against a loaded lib, guarding the lookup itself
-- (lib[sym] throws "undefined symbol" for absent symbols).
local function resolve(ffi, lib, sym)
    local ok, fn = pcall(function() return lib[sym] end)
    if not ok or not fn then return false end
    -- LuaJIT NULL cdata is truthy; check via uintptr cast.
    local pok, n = pcall(function() return tonumber(ffi.cast("uintptr_t", fn)) end)
    return pok and n ~= 0
end

-- Load a candidate lib guardedly; returns lib handle or nil.
local function load_lib(ffi, libname)
    local ok, lib = pcall(ffi.load, libname)
    if ok then return lib end
    return nil
end

function audio_probe.run_capability_scan()
    local lines = {}
    local function out(s) table.insert(lines, tostring(s)) end
    local function section(t) out(""); out("==== " .. t .. " ====") end

    out("absaudio capability scan v1 (FFmpeg+ALSA symbol resolution)")
    out("run: " .. os.date("%Y-%m-%d %H:%M:%S"))

    local ffi_ok, ffi = pcall(require, "ffi")
    if not ffi_ok then
        out("FATAL: require('ffi') failed — cannot probe. " .. tostring(ffi))
        local report = table.concat(lines, "\n") .. "\n"
        local rf = io.open(audio_probe.REPORT_PATH, "w")
        if rf then rf:write(report); rf:close() end
        return report
    end

    -- Declare the cdefs the backend needs (guarded, same as audio_ffi.lua).
    -- We only need the symbol PRESENT; we never CALL them here.
    pcall(ffi.cdef, [[
        struct AVFormatContext; struct AVCodecContext; struct AVFrame;
        struct AVPacket; struct SwrContext; struct AVCodec; struct AVStream;
        struct AVRational { int num; int den; };
        struct snd_pcm; typedef struct snd_pcm snd_pcm_t;

        int avformat_open_input(struct AVFormatContext **ps, const char *url,
                                const void *fmt, void **options);
        int avformat_find_stream_info(struct AVFormatContext *ic, void **options);
        int av_read_frame(struct AVFormatContext *s, struct AVPacket *pkt);
        void avformat_close_input(struct AVFormatContext **s);
        int av_seek_frame(struct AVFormatContext *s, int stream_index,
                          long long timestamp, int flags);

        int av_find_best_stream(struct AVFormatContext *ic, int type,
                                int wanted_stream, int related, const struct AVCodec **dec,
                                int flags);
        const struct AVCodec *avcodec_find_decoder(int codec_id);
        int avcodec_open2(struct AVCodecContext *avctx, const void *codec, void **options);
        void avcodec_close(struct AVCodecContext *avctx);
        void avcodec_free_context(struct AVCodecContext **avctx);
        int avcodec_send_packet(struct AVCodecContext *avctx, const struct AVPacket *avpkt);
        int avcodec_receive_frame(struct AVCodecContext *avctx, struct AVFrame *frame);
        struct AVPacket *av_packet_alloc(void);
        void av_packet_unref(struct AVPacket *pkt);
        void av_packet_free(struct AVPacket **pkt);
        struct AVFrame *av_frame_alloc(void);
        void av_frame_free(struct AVFrame **frame);

        struct SwrContext *swr_alloc(void);
        struct SwrContext *swr_alloc_set_opts(struct SwrContext *s,
            long long out_ch_layout, int out_sample_fmt, int out_sample_rate,
            long long in_ch_layout,  int in_sample_fmt, int in_sample_rate,
            int log_level_offset, void *log_ctx);
        int swr_init(struct SwrContext *s);
        int swr_convert(struct SwrContext *s, uint8_t **out, int out_count,
                        const uint8_t **in, int in_count);
        void swr_free(struct SwrContext **s);
        int av_opt_set_int(void *obj, const char *name, long long val, int search_flags);
        int av_opt_set_sample_fmt(void *obj, const char *name, int fmt, int search_flags);
        int av_get_bytes_per_sample(int sample_fmt);
        int av_samples_get_buffer_size(int *linesize, int nb_channels,
                                       int nb_samples, int sample_fmt, int align);

        int snd_pcm_open(snd_pcm_t **pcm, const char *name, int stream, int mode);
        int snd_pcm_set_params(snd_pcm_t *pcm, int format, int access,
                               unsigned int channels, unsigned int rate,
                               int soft_resample, unsigned int latency);
        long snd_pcm_writei(snd_pcm_t *pcm, const void *buffer, unsigned long size);
        int snd_pcm_drain(snd_pcm_t *pcm);
        int snd_pcm_close(snd_pcm_t *pcm);
        int snd_pcm_recover(snd_pcm_t *pcm, int err, int silent);
        const char *snd_strerror(int err);

        void *open_alsa(const char *device);
        void *open_alsa_ex(const char *device);
        int push_output_buffer(void *handle, const void *data, int size);
        void *get_output_buffer(void *handle);
        int alsa_output_working(void);
        int init_alsa_output(void);
        int deinit_alsa_output(void);
        int pause_alsa(void);
    ]])

    -- 1. Load candidate libs
    section("1. LIBRARY LOADS")
    local libs = {}  -- libname -> handle (or nil)
    for _, cand in ipairs(CANDIDATE_LIBS) do
        local lib = load_lib(ffi, cand.name)
        libs[cand.name] = lib
        out(string.format("  %-14s %s — %s", cand.name,
            lib and "LOADED" or "FAILED", cand.desc))
    end

    -- 2. Resolve each symbol group across all loaded libs; record first .so hit.
    local function scan_group(label, group)
        section("2. " .. label .. " symbol resolution")
        local resolved, missing = 0, 0
        local first_lib = {}  -- sym -> libname where it resolved
        for _, sym in ipairs(group) do
            local found_in = nil
            for _, cand in ipairs(CANDIDATE_LIBS) do
                local lib = libs[cand.name]
                if lib and resolve(ffi, lib, sym) then
                    found_in = cand.name
                    break
                end
            end
            if found_in then
                resolved = resolved + 1
                first_lib[sym] = found_in
                out(string.format("  %-30s OK (%s)", sym, found_in))
            else
                missing = missing + 1
                out(string.format("  %-30s <MISSING>", sym))
            end
        end
        out(string.format("  → %d/%d resolved, %d missing", resolved, #group, missing))
        return first_lib, missing == 0
    end

    local decode_map, decode_ok = scan_group("DECODE", CAP_DECODE)
    local swr_map, swr_ok       = scan_group("SWR (resample)", CAP_SWR)
    local alsa_map, alsa_ok     = scan_group("ALSA raw (snd_pcm_*)", CAP_ALSA_RAW)
    local ae_map, ae_ok         = scan_group("audio-engine output helpers", CAP_AUDIOENGINE)

    -- 3. Verdict
    section("3. VERDICT")
    out(string.format("DECODE pipeline ready:        %s", decode_ok and "YES" or "NO — missing symbols"))
    out(string.format("SWR resample ready:           %s", swr_ok and "YES" or "NO — missing symbols"))
    out(string.format("ALSA raw (snd_pcm_writei):    %s", alsa_ok and "YES" or "NO — missing symbols"))
    out(string.format("audio-engine output helpers:  %s", ae_ok and "YES" or "NO — missing symbols"))
    out("")
    if decode_ok and swr_ok then
        out("→ FFmpeg decode producer is viable: build decoder_factory using the")
        out("  lib each symbol resolved from above.")
    else
        out("→ DECODE/SWR has gaps — the missing symbols must be found or worked")
        out("  around before writing the decoder_factory.")
    end
    if alsa_ok then
        out("→ Raw ALSA output via snd_pcm_open(\"tts_sm\") is viable.")
    elseif ae_ok then
        out("→ Raw ALSA missing, but libaudio-engine output helpers available —")
        out("  use open_alsa/push_output_buffer instead (preferred: amplifier-aware).")
    else
        out("→ BOTH output paths missing symbols — cannot output audio yet.")
    end

    local report = table.concat(lines, "\n") .. "\n"
    local rf = io.open(audio_probe.REPORT_PATH, "w")
    if rf then rf:write(report); rf:close() end
    return report
end

-- =====================================================================
-- DECODE LAYOUT PROBE (issue #34 slice C, device)
--
-- GOAL: verify FFmpeg 6.0 struct field offsets on THIS device before writing
-- the real decoder_factory. Opens a real downloaded M4B, decodes one frame,
-- and dumps the actual values at candidate offsets for AVCodecParameters,
-- AVCodecContext, AVFrame, AVStream. Cross-verifies by scanning for expected
-- values (44100/48000 for sample_rate, 1/2 for channels). Never opens ALSA.
--
-- The decoder_factory code is written against the offsets confirmed here.
-- =====================================================================

-- FFmpeg 6.0 constants
local AVMEDIA_TYPE_AUDIO = 1
local AV_SAMPLE_FMT_S16  = 1   -- interleaved signed 16-bit
local AV_SAMPLE_FMT_FLTP = 8   -- planar signed 32-bit float (AAC default decode)
local AV_CH_LAYOUT_STEREO = 3

-- FFmpeg 6.0 struct layouts (64-bit). Only the fields we need; padding
-- via char arrays for fields we skip. These are the CANONICAL layouts from
-- libavcodec/frame.h, codec_par.h, avcodec.h for FFmpeg 6.0 (libavcodec 60).
-- The probe CROSS-VERIFIES by scanning for expected values.
local DECODE_CDEFS = [[
    struct AVRational { int num; int den; };

    /* AVFrame — only read data[0], linesize, nb_samples, format, pts */
    struct AVFrame {
        uint8_t *data[8];           /*   0: data planes */
        int linesize[8];            /*  64: line sizes */
        uint8_t *extended_data;     /*  96 */
        int width;                  /* 104 */
        int height;                 /* 108 */
        int nb_samples;             /* 112: SAMPLES PER CHANNEL */
        int format;                 /* 116: AVSampleFormat */
        int key_frame;              /* 120 */
        int pict_type;              /* 124 */
        uint8_t *base[8];           /* 128: @deprecated */
        int64_t pts;                /* 192: BEST-EFFORT PTS (may be AV_NOPTS_VALUE) */
        int64_t pkt_dts;            /* 200 */
        int64_t time_base;          /* 208: time base */
        int coded_picture_number;   /* 216 */
        int display_picture_number; /* 220 */
        int quality;                /* 224 */
        int opaque;                 /* 228 */
        int repeat_pict;            /* 232 */
        int interlaced_frame;       /* 236 */
        int top_field_first;        /* 240 */
        int palette_has_changed;    /* 244 */
        int64_t reordered_opaque;   /* 248 */
        int sample_rate;            /* 256 */
        uint64_t channel_layout;    /* 264: DEPRECATED in 6.0 but still present */
        /* ... remaining fields not needed ... */
    };

    /* AVCodecParameters — from stream->codecpar */
    struct AVCodecParameters {
        int codec_type;             /*   0: AVMediaType */
        int codec_id;               /*   4: AVCodecID */
        uint32_t codec_tag;         /*   8 */
        uint8_t *extradata;         /*  16: aligned */
        int extradata_size;         /*  24 */
        int format;                 /*  28: AVSampleFormat for audio */
        int64_t bit_rate;           /*  32 */
        int bits_per_coded_sample;  /*  40 */
        int bits_per_raw_sample;    /*  44 */
        int profile;                /*  48 */
        int level;                  /*  52 */
        int width;                  /*  56: video */
        int height;                 /*  60: video */
        /* FFmpeg 6.0: AVChannelLayout ch_layout here (it's a struct with
         * union { uint64_t mask; AVChannelCustom *map; } + enum + nb_channels)
         * AVChannelLayout = { enum AVChannelOrder order (4 bytes)
         *                    + int nb_channels (4 bytes)
         *                    + union { uint64_t mask (8 bytes) | ... } }
         * So at offset 64: order (int), 68: nb_channels (int),
         * 72: mask (uint64_t) OR the pre-6.0 layout had:
         *   int sample_rate; uint64_t channel_layout; int channels;
         * We scan for both layouts in the probe. */
        int _pad0;                  /*  64 */
        int sample_rate;            /*  68: CANDIDATE A (pre-6.0 layout) */
        uint64_t channel_layout;    /*  72: CANDIDATE A */
        int channels;               /*  80: CANDIDATE A */
        /* ... remaining ... */
    };

    /* AVStream — need time_base + codecpar */
    /* AVStream (FFmpeg 6.0, 64-bit) — codecpar at offset 16, time_base at 24 */
    struct AVStream {
        int index;                           /*   0 */
        int id;                              /*   4 */
        void *priv_data;                     /*   8 */
        struct AVCodecParameters *codecpar;  /*  16: KEY FIELD */
        struct AVRational time_base;         /*  24: {num, den} */
        /* remaining fields opaque */
    };

    /* AVFormatContext (FFmpeg 6.0, 64-bit) — nb_streams at 44, streams at 48 */
    struct AVFormatContext {
        void *av_class;                    /*   0 */
        void *iformat;                     /*   8 */
        void *oformat;                     /*  16 */
        void *priv_data;                   /*  24 */
        void *pb;                          /*  32: AVIOContext* */
        int ctx_flags;                     /*  40 */
        unsigned int nb_streams;           /*  44: KEY FIELD */
        struct AVStream **streams;         /*  48: KEY FIELD */
        char *url;                         /*  56 */
        /* remaining fields opaque */
    };

    /* AVPacket — opaque, we just need it to exist for send_packet */
    struct AVPacket { char _opaque_pkt[64]; };

    struct AVCodec { char _opaque_codec[128]; };

    struct AVCodecContext *avcodec_alloc_context3(const struct AVCodec *codec);
    int avcodec_parameters_to_context(struct AVCodecContext *codec, const void *par);
    void avcodec_free_context(struct AVCodecContext **avctx);
    /* FFmpeg functions used by the decode probe */
    int avformat_open_input(struct AVFormatContext **ps, const char *url,
                            const void *fmt, void **options);
    int avformat_find_stream_info(struct AVFormatContext *ic, void **options);
    int av_read_frame(struct AVFormatContext *s, struct AVPacket *pkt);
    void avformat_close_input(struct AVFormatContext **s);
    int av_find_best_stream(struct AVFormatContext *ic, int type,
                            int wanted_stream, int related_stream,
                            const struct AVCodec **decoder_ret, int flags);
    int avcodec_open2(struct AVCodecContext *avctx, const void *codec, void **options);
    int avcodec_send_packet(struct AVCodecContext *avctx, const struct AVPacket *pkt);
    int avcodec_receive_frame(struct AVCodecContext *avctx, struct AVFrame *frame);
    struct AVPacket *av_packet_alloc(void);
    void av_packet_unref(struct AVPacket *pkt);
    void av_packet_free(struct AVPacket **pkt);
    struct AVFrame *av_frame_alloc(void);
    void av_frame_free(struct AVFrame **frame);
    void av_frame_unref(struct AVFrame *frame);
]]

-- Additional cdefs for play-test probe (swresample, ALSA, audio-engine helpers).
-- These are pcall-guarded at runtime (duplicate declarations are harmless).
local PLAY_CDEFS = [[
    /* swresample */
    struct SwrContext;
    struct SwrContext *swr_alloc(void);
    struct SwrContext *swr_alloc_set_opts(struct SwrContext *s,
        long long out_ch_layout, int out_sample_fmt, int out_sample_rate,
        long long in_ch_layout, int in_sample_fmt, int in_sample_rate,
        int log_offset, void *log_ctx);
    int swr_init(struct SwrContext *s);
    int swr_convert(struct SwrContext *s, uint8_t **out, int out_count,
                    const uint8_t **in, int in_count);
    void swr_free(struct SwrContext **s);

    /* ALSA raw (from capability scan) */
    typedef struct _snd_pcm snd_pcm_t;
    int snd_pcm_open(snd_pcm_t **pcm, const char *name, int stream, int mode);
    int snd_pcm_set_params(snd_pcm_t *pcm, int format, int access,
                           unsigned int channels, unsigned int rate,
                           int soft_resample, unsigned int latency);
    long snd_pcm_writei(snd_pcm_t *pcm, const void *buffer, unsigned long size);
    int snd_pcm_prepare(snd_pcm_t *pcm);
    int snd_pcm_drain(snd_pcm_t *pcm);
    int snd_pcm_close(snd_pcm_t *pcm);

    /* audio-engine helpers (from capability scan) */
    void *open_alsa(const char *device);
    int push_output_buffer(void *handle, const void *data, int size);
    int alsa_output_working(void);
]]

-- Find a test M4B file in the download dir.
local function find_test_m4b()
    local search_info = { dir = nil, error = nil }
    local ok_cfg, config = pcall(require, "config")
    if not ok_cfg then
        search_info.error = "require('config') failed: " .. tostring(config)
        return nil, search_info
    end
    local ok_dir, dir = pcall(function() return config.get_download_dir() end)
    if not ok_dir then
        search_info.error = "config.get_download_dir() threw: " .. tostring(dir)
        return nil, search_info
    end
    search_info.dir = dir
    if not dir then return nil, search_info end

    local lfs_ok, lfs = pcall(require, "lfs")
    if not lfs_ok then lfs = _G.lfs end
    if not lfs then
        search_info.error = "lfs not available"
        return nil, search_info
    end

    -- Check existence with lfs.attributes (safe, never throws).
    -- Do NOT pcall lfs.dir itself — on PocketBook it returns a 3-tuple
    -- (gen, state, ctrl) and pcall discards state+ctrl, breaking iteration.
    local dir_mode = lfs.attributes(dir, "mode")
    if dir_mode ~= "directory" then
        search_info.error = "download dir does not exist: " .. tostring(dir) ..
            " (mode=" .. tostring(dir_mode) .. ")"
        return nil, search_info
    end

    -- Search one level deep for a .m4b/.m4a/.mp4
    local function is_audio(name)
        local lower = name:lower()
        return lower:match("%.m4b$") or lower:match("%.m4a$") or lower:match("%.mp4$")
    end

    for name in lfs.dir(dir) do
        local path = dir .. "/" .. name
        local mode = lfs.attributes(path, "mode")
        if mode == "directory" and name ~= "." and name ~= ".." then
            for fname in lfs.dir(path) do
                if is_audio(fname) then
                    local full = path .. "/" .. fname
                    if lfs.attributes(full, "mode") == "file" then
                        return full, search_info
                    end
                end
            end
        elseif mode == "file" and is_audio(name) then
            return path, search_info
        end
    end
    return nil, search_info
end

function audio_probe.run_decode_layout_probe()
    -- Open report file IMMEDIATELY and flush after every line.
    -- This survives native SIGSEGV crashes (which xpcall cannot catch):
    -- everything written before the crash is preserved on disk.
    local rf = io.open(audio_probe.REPORT_PATH, "w")
    local lines = {}
    local function out(s)
        local line = tostring(s)
        table.insert(lines, line)
        if rf then rf:write(line, "\n"); rf:flush() end
    end
    local function section(t) out(""); out("==== " .. t .. " ====") end
    local function write_report()
        if rf then rf:close(); rf = nil end
        return table.concat(lines, "\n") .. "\n"
    end

    local function body()
        out("absaudio decode layout probe v2 (safe struct access)")
        out("run: " .. os.date("%Y-%m-%d %H:%M:%S"))

        local ffi_ok, ffi = pcall(require, "ffi")
        if not ffi_ok then
            out("FATAL: require('ffi') failed - " .. tostring(ffi))
            return write_report()
        end
        local bit_ok, bit = pcall(require, "bit")
        if not bit_ok then
            out("FATAL: require('bit') failed - " .. tostring(bit))
            return write_report()
        end

        local cdef_ok, cdef_err = pcall(ffi.cdef, DECODE_CDEFS)
        if not cdef_ok then
            out("NOTE: ffi.cdef (may be already declared): " .. tostring(cdef_err))
        end

        local ok_lib, lib = pcall(ffi.load, "audio-engine")
        if not ok_lib then
            out("FATAL: ffi.load('audio-engine') failed - " .. tostring(lib))
            return write_report()
        end

        -- Find a test file
        local test_file, search_info = find_test_m4b()
        section("0. TEST FILE")
        out("download dir searched: " .. tostring(search_info.dir))
        if search_info.error then
            out("search error: " .. search_info.error)
        end
        if not test_file then
            out("No .m4b/.m4a/.mp4 found in download dir.")
            return write_report()
        end
        out("file: " .. test_file)
        local lfs_ok, lfs = pcall(require, "lfs")
        if not lfs_ok then lfs = _G.lfs end
        if lfs then
            local sz = lfs.attributes(test_file, "size")
            out(string.format("size: %d bytes (%.1f MB)", sz or -1, (sz or 0) / 1048576))
        end

        ---- Open the file ----
        section("1. OPEN")
        local fmt_ctx_ptr = ffi.new("struct AVFormatContext*[1]")
        local cpath = ffi.new("const char[?]", #test_file + 1, test_file)
        local ret = lib.avformat_open_input(fmt_ctx_ptr, cpath, nil, nil)
        out(string.format("avformat_open_input -> %d (0 = OK)", ret))
        if ret ~= 0 then
            out("FAILED to open file.")
            return write_report()
        end
        local fmt_ctx = fmt_ctx_ptr[0]

        -- find_stream_info is SLOW on M4B (probes the file, 10-30s)
        out("calling avformat_find_stream_info (may take 10-30s)...")
        ret = lib.avformat_find_stream_info(fmt_ctx, nil)
        out(string.format("avformat_find_stream_info -> %d", ret))

        local stream_idx = lib.av_find_best_stream(fmt_ctx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        out(string.format("av_find_best_stream(AUDIO) -> %d (>= 0 = OK)", stream_idx))
        if stream_idx < 0 then
            out("No audio stream found.")
            lib.avformat_close_input(fmt_ctx_ptr)
            return write_report()
        end

        ---- SAFE STRUCT ACCESS (no blind pointer derefs) ----
        section("2. FORMAT CONTEXT (struct field access)")
        local fmt = ffi.cast("struct AVFormatContext*", fmt_ctx)
        out(string.format("nb_streams  (offset 44) = %d", fmt.nb_streams))
        out(string.format("streams ptr (offset 48) = 0x%x", tonumber(ffi.cast("uintptr_t", fmt.streams)) or 0))

        -- Access stream via streams[idx] — this pointer is KNOWN-GOOD (FFmpeg set it)
        local stream = fmt.streams[stream_idx]
        out(string.format("streams[%d] = 0x%x", stream_idx, tonumber(ffi.cast("uintptr_t", stream)) or 0))

        ---- CODECPAR (struct field access at AVStream offset 16) ----
        section("3. CODECPAR (struct field at stream offset 16)")
        local st = ffi.cast("struct AVStream*", stream)
        out(string.format("index (offset 0)     = %d", st.index))
        out(string.format("id (offset 4)        = %d", st.id))
        local codecpar = st.codecpar  -- offset 16, KNOWN-GOOD pointer from FFmpeg
        out(string.format("codecpar (offset 16) = 0x%x", tonumber(ffi.cast("uintptr_t", codecpar)) or 0))
        out(string.format("time_base (offset 24)= {%d, %d}", st.time_base.num, st.time_base.den))

        if codecpar == nil or tonumber(ffi.cast("uintptr_t", codecpar)) == 0 then
            out("FATAL: codecpar is NULL. Cannot continue.")
            lib.avformat_close_input(fmt_ctx_ptr)
            return write_report()
        end

        ---- CODECPAR RAW DUMP (int32 — SAFE: reading within allocated memory) ----
        section("4. CODECPAR RAW DUMP (int32, first 128 bytes)")
        local cp = ffi.cast("uint8_t*", codecpar)
        for off = 0, 124, 4 do
            local val = ffi.cast("int32_t*", cp + off)[0]
            local note = ""
            if val == 44100 then note = " <- sample_rate 44100?" end
            if val == 48000 then note = " <- sample_rate 48000?" end
            if val == 22050 then note = " <- sample_rate 22050?" end
            if val == 1 then note = note .. " (AUDIO? S16? mono?)" end
            if val == 2 then note = note .. " (stereo? S32?)" end
            if val == 3 then note = note .. " (FLT? ch_layout?)" end
            if val == 640602 then note = " <- codec_id AAC?" end
            if val == 86018 then note = " <- codec_id AAC?" end
            out(string.format("  +%3d: %12d  (0x%08x)%s", off, val, bit.band(val, 0xFFFFFFFF), note))
        end

        section("5. CODECPAR RAW DUMP (int64, for bit_rate/channel_layout)")
        for off = 0, 120, 8 do
            local val = tonumber(ffi.cast("int64_t*", cp + off)[0]) or 0
            local note = ""
            if val == 3 then note = " <- AV_CH_LAYOUT_STEREO?" end
            if val == 4 then note = " <- AV_CH_LAYOUT_QUAD?" end
            out(string.format("  +%3d: %20d  (0x%016x)%s", off, val, val, note))
        end

        ---- DECODE ONE FRAME ----
        section("7. DECODE ONE FRAME")
        local codec_ptr = ffi.new("const struct AVCodec*[1]")
        lib.av_find_best_stream(fmt_ctx, AVMEDIA_TYPE_AUDIO, -1, -1, codec_ptr, 0)
        local codec = codec_ptr[0]
        out(string.format("codec ptr = 0x%x", tonumber(ffi.cast("uintptr_t", codec)) or 0))

        local ctx = lib.avcodec_alloc_context3(codec)
        out(string.format("avcodec_alloc_context3 -> 0x%x", tonumber(ffi.cast("uintptr_t", ctx)) or 0))

        ret = lib.avcodec_parameters_to_context(ctx, codecpar)
        out(string.format("avcodec_parameters_to_context -> %d", ret))

        ret = lib.avcodec_open2(ctx, codec, nil)
        out(string.format("avcodec_open2 -> %d (0 = OK)", ret))

        if ret == 0 then
            -- ---- CODEC CONTEXT RAW DUMP (after open) ----
            section("6. CODEC CONTEXT (raw int32 dump after open)")
            local craw = ffi.cast("uint8_t*", ctx)
            local ctx_known = {
                [86018] = "codec_id AAC",
                [22050] = "sample_rate 22050",
                [48000] = "sample_rate 48000",
                [44100] = "sample_rate 44100",
                [8] = "sample_fmt FLTP?",
                [1] = "sample_fmt S16? / ch_layout",
                [2] = "channels 2? / S32?",
                [3] = "channel_layout STEREO?",
                [1024] = "frame_size 1024 (AAC)",
            }
            for off = 0, 400, 4 do
                local val = ffi.cast("int32_t*", craw + off)[0]
                local note = ctx_known[val] or ""
                out(string.format("  +%3d: %12d  (0x%08x) %s", off, val,
                    bit.band(val, 0xFFFFFFFF), note))
            end

            out("")
            out("  Cross-verify: scan for time_base {1, 22050}:")
            for off = 0, 400, 4 do
                local num = ffi.cast("int32_t*", craw + off)[0]
                local den = ffi.cast("int32_t*", craw + off + 4)[0]
                if num == 1 and (den == 22050 or den == 48000 or den == 44100) then
                    out(string.format("    +%3d: {1, %d} <- TIME_BASE", off, den))
                end
            end

            section("7. DECODE ONE FRAME")
            local pkt = lib.av_packet_alloc()
            local frame = lib.av_frame_alloc()
            local got_frame = false
            for i = 1, 100 do
                ret = lib.av_read_frame(fmt_ctx, pkt)
                if ret < 0 then
                    out(string.format("av_read_frame exhausted after %d packets (ret=%d)", i, ret))
                    break
                end
                lib.avcodec_send_packet(ctx, pkt)
                lib.av_packet_unref(pkt)
                ret = lib.avcodec_receive_frame(ctx, frame)
                if ret == 0 then
                    got_frame = true
                    out(string.format("decoded frame on packet %d", i))
                    break
                end
            end

            if got_frame then
                out("")
                out("AVFrame field dump (at declared offsets):")
                local fraw = ffi.cast("struct AVFrame*", frame)
                out(string.format("  data[0]      (off   0) = 0x%x", tonumber(ffi.cast("uintptr_t", fraw.data[0])) or 0))
                out(string.format("  linesize[0]  (off  64) = %d", fraw.linesize[0]))
                out(string.format("  nb_samples   (off 112) = %d", fraw.nb_samples))
                out(string.format("  format       (off 116) = %d (1=S16 3=FLT)", fraw.format))
                out(string.format("  pts          (off 192) = %d", tonumber(fraw.pts) or 0))
                out(string.format("  sample_rate  (off 256) = %d", fraw.sample_rate))
                out(string.format("  channel_lay  (off 264) = 0x%x", tonumber(fraw.channel_layout) or 0))

                out("")
                out("  Cross-verify: scan frame bytes for sample_rate value:")
                local fb = ffi.cast("uint8_t*", frame)
                for off = 0, 280, 4 do
                    local val = ffi.cast("int32_t*", fb + off)[0]
                    if val == 44100 or val == 48000 or val == 22050 then
                        out(string.format("    +%3d: %d <- sample_rate FOUND", off, val))
                    end
                end
            else
                out("FAILED to decode a frame (ret=" .. tostring(ret) .. ")")
            end

            lib.av_frame_free(ffi.new("struct AVFrame*[1]", {frame}))
            lib.av_packet_free(ffi.new("struct AVPacket*[1]", {pkt}))
        else
            out("avcodec_open2 failed — cannot decode")
        end

        lib.avcodec_free_context(ffi.new("struct AVCodecContext*[1]", {ctx}))
        lib.avformat_close_input(fmt_ctx_ptr)

        section("8. VERDICT")
        out("Compare offsets above with struct declarations.")
        out("The decoder_factory is written against the offsets confirmed here.")

        return write_report()
    end

    -- Run body with crash protection; ALWAYS write a report file.
    local ok, result = xpcall(body, function(e)
        return tostring(e) .. "\n" .. debug.traceback()
    end)
    if ok then
        return result
    end
    out("")
    out("==== PROBE CRASHED (uncaught Lua error) ====")
    out(tostring(result))
    return write_report()
end

--- Minimal play-test probe: decode ~5s of a real M4B, convert FLTP->S16 via
--- swresample, and push to ALSA. Verifies actual sound output on-device.
--- Uses ONLY confirmed struct offsets from the decode layout probe.
function audio_probe.run_play_test()
    -- Incremental report writes (survive native crashes).
    local rf = io.open(audio_probe.REPORT_PATH, "w")
    local lines = {}
    local function out(s)
        local line = tostring(s)
        table.insert(lines, line)
        if rf then rf:write(line, "\n"); rf:flush() end
    end
    local function section(t) out(""); out("==== " .. t .. " ====") end
    local function write_report()
        if rf then rf:close(); rf = nil end
        return table.concat(lines, "\n") .. "\n"
    end

    local function body()
        out("absaudio play-test probe v1")
        out("run: " .. os.date("%Y-%m-%d %H:%M:%S"))

        local ffi_ok, ffi = pcall(require, "ffi")
        if not ffi_ok then
            out("FATAL: " .. tostring(ffi))
            return write_report()
        end
        local bit_ok, bit = pcall(require, "bit")
        if not bit_ok then
            out("FATAL: " .. tostring(bit))
            return write_report()
        end

        -- Declare all cdefs (guarded — duplicates are harmless).
        pcall(ffi.cdef, DECODE_CDEFS)
        pcall(ffi.cdef, PLAY_CDEFS)

        local ok_lib, lib = pcall(ffi.load, "audio-engine")
        if not ok_lib then
            out("FATAL: ffi.load('audio-engine') - " .. tostring(lib))
            return write_report()
        end

        ---- ALSA HARDWARE ENUMERATION ----
        section("0.5. ALSA HARDWARE (proc + /dev/snd/)")
        -- Read proc filesystem text files to enumerate audio hardware.
        local proc_files = {
            "/proc/asound/cards",
            "/proc/asound/pcm",
            "/proc/asound/devices",
            "/proc/asound/modules",
        }
        for _, pf in ipairs(proc_files) do
            local f = io.open(pf, "r")
            if f then
                out(">>> " .. pf .. ":")
                local content = f:read("*a")
                f:close()
                -- Truncate to 500 chars to keep report manageable
                if #content > 500 then content = content:sub(1, 500) .. "...(truncated)" end
                for line in content:gmatch("[^\n]+") do
                    out("  " .. line)
                end
            else
                out(">>> " .. pf .. ": (not found)")
            end
        end

        -- List /dev/snd/ directory
        local lfs_ok2, lfs2 = pcall(require, "lfs")
        if not lfs_ok2 then lfs2 = _G.lfs end
        if lfs2 then
            out(">>> /dev/snd/ contents:")
            local ok_devdir = pcall(function()
                for name in lfs2.dir("/dev/snd") do
                    local info = lfs2.attributes("/dev/snd/" .. name, "mode") or "?"
                    out("  " .. name .. " (" .. tostring(info) .. ")")
                end
            end)
            if not ok_devdir then
                out("  (cannot read /dev/snd)")
            end
        end

        -- Find test file
        local test_file, search_info = find_test_m4b()
        section("0. TEST FILE")
        out("file: " .. tostring(test_file or "NONE"))
        if not test_file then
            out("error: " .. tostring(search_info.error))
            return write_report()
        end

        -- Open file
        section("1. OPEN FILE")
        local fmt_ctx_ptr = ffi.new("struct AVFormatContext*[1]")
        local cpath = ffi.new("const char[?]", #test_file + 1, test_file)
        local ret = lib.avformat_open_input(fmt_ctx_ptr, cpath, nil, nil)
        out(string.format("avformat_open_input -> %d", ret))
        if ret ~= 0 then return write_report() end
        local fmt_ctx = fmt_ctx_ptr[0]

        out("calling avformat_find_stream_info (may take 10-30s)...")
        lib.avformat_find_stream_info(fmt_ctx, nil)
        local stream_idx = lib.av_find_best_stream(fmt_ctx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        out(string.format("audio stream idx = %d", stream_idx))
        if stream_idx < 0 then
            lib.avformat_close_input(fmt_ctx_ptr)
            return write_report()
        end

        local fmt = ffi.cast("struct AVFormatContext*", fmt_ctx)
        local stream = fmt.streams[stream_idx]
        local st = ffi.cast("struct AVStream*", stream)
        local codecpar = st.codecpar

        -- Read sample_rate/channels/ch_layout from codecpar at confirmed offsets
        local cp = ffi.cast("uint8_t*", codecpar)
        local in_sample_rate = ffi.cast("int32_t*", cp + 108)[0]  -- offset 108
        local in_channels = ffi.cast("int32_t*", cp + 104)[0]     -- offset 104
        local in_ch_layout = ffi.cast("int64_t*", cp + 96)[0]     -- offset 96
        out(string.format("codecpar: rate=%d ch=%d layout=0x%x",
            in_sample_rate, in_channels, tonumber(in_ch_layout) or 0))

        -- Open codec
        section("2. OPEN CODEC")
        local codec_ptr = ffi.new("const struct AVCodec*[1]")
        lib.av_find_best_stream(fmt_ctx, AVMEDIA_TYPE_AUDIO, -1, -1, codec_ptr, 0)
        local codec = codec_ptr[0]
        local ctx = lib.avcodec_alloc_context3(codec)
        lib.avcodec_parameters_to_context(ctx, codecpar)
        ret = lib.avcodec_open2(ctx, codec, nil)
        out(string.format("avcodec_open2 -> %d", ret))
        if ret ~= 0 then
            lib.avformat_close_input(fmt_ctx_ptr)
            return write_report()
        end

        -- Setup swresample: FLTP -> S16, same rate, same channels
        section("3. SWRESAMPLE SETUP")
        local AV_SAMPLE_FMT_S16 = 1
        local swr = lib.swr_alloc()
        out(string.format("swr_alloc -> 0x%x", tonumber(ffi.cast("uintptr_t", swr)) or 0))
        local swr2 = lib.swr_alloc_set_opts(swr,
            in_ch_layout, AV_SAMPLE_FMT_S16, in_sample_rate,  -- output
            in_ch_layout, AV_SAMPLE_FMT_FLTP, in_sample_rate, -- input
            0, nil)
        out(string.format("swr_alloc_set_opts -> 0x%x", tonumber(ffi.cast("uintptr_t", swr2)) or 0))
        ret = lib.swr_init(swr2)
        out(string.format("swr_init -> %d", ret))

        -- Open ALSA output -- try raw ALSA with several device names.
        -- The audio-engine open_alsa() returned 0x1 (a status code, not a
        -- pointer), so push_output_buffer was called with a bogus handle.
        -- Skip it and use raw ALSA directly.
        section("4. ALSA OUTPUT (raw)")
        local pcm = nil
        local alsa_device = nil

        -- Try real hardware first. tts_sm is a virtual device that silently
        -- swallows audio (not in /proc/asound/pcm). The SUNXI-CODEC card 0
        -- is the physical DAC; aif1 (hw:0,0) is the main speaker output.
        local devices = { "plughw:0,0", "hw:0,0", "plughw:0,1", "hw:0,1", "default" }
        for _, devname in ipairs(devices) do
            local pcm_ptr = ffi.new("snd_pcm_t*[1]")
            ret = lib.snd_pcm_open(pcm_ptr, devname, 0, 0)  -- STREAM_PLAYBACK=0, BLOCK=0
            out(string.format("snd_pcm_open('%s') -> %d", devname, ret))
            if ret >= 0 then
                pcm = pcm_ptr[0]
                alsa_device = devname
                -- Configure: format=S16_LE(2), access=RW_INTERLEAVED(3),
                -- channels, rate, soft_resample=1, latency=500000us (0.5s)
                ret = lib.snd_pcm_set_params(pcm, 2, 3, in_channels, in_sample_rate, 1, 500000)
                out(string.format("snd_pcm_set_params('%s') -> %d", devname, ret))
                if ret < 0 then
                    out(string.format("set_params failed for '%s', trying next...", devname))
                    lib.snd_pcm_close(pcm)
                    pcm = nil
                    alsa_device = nil
                else
                    out(string.format("SUCCESS: opened '%s'", devname))
                    break
                end
            end
        end

        if pcm == nil then
            out("FATAL: All ALSA open attempts failed. Cannot play audio.")
            lib.avformat_close_input(fmt_ctx_ptr)
            return write_report()
        end

        -- Decode and play ~5 seconds
        section("5. DECODE AND PLAY (~5 seconds)")
        local pkt = lib.av_packet_alloc()
        local frame = lib.av_frame_alloc()

        -- S16 interleaved output buffer (max 2048 samples/channel to handle resample headroom)
        local out_buf = ffi.new("int16_t[4096]")  -- 2048 samples * 2ch
        local out_ptrs = ffi.new("uint8_t*[1]")
        out_ptrs[0] = ffi.cast("uint8_t*", out_buf)
        local in_ptrs = ffi.new("const uint8_t*[2]")

        local frames_played = 0
        local total_samples = 0
        local max_frames = 120  -- ~5-6 seconds at 22050/1024 ~= 108 frames/sec

        for i = 1, max_frames do
            ret = lib.av_read_frame(fmt_ctx, pkt)
            if ret < 0 then
                out(string.format("av_read_frame EOF/error at %d (ret=%d)", i, ret))
                break
            end
            lib.avcodec_send_packet(ctx, pkt)
            lib.av_packet_unref(pkt)
            ret = lib.avcodec_receive_frame(ctx, frame)
            if ret ~= 0 then
                -- skip non-decodable packets
            else
                local nb = frame.nb_samples
                -- Setup input pointers for FLTP (planar: data[0]=L, data[1]=R)
                in_ptrs[0] = ffi.cast("uint8_t*", frame.data[0])
                in_ptrs[1] = ffi.cast("uint8_t*", frame.data[1])

                -- Convert FLTP -> S16 interleaved
                local nsamp = lib.swr_convert(swr2, out_ptrs, 2048, in_ptrs, nb)
                if nsamp > 0 then
                    local wrote = lib.snd_pcm_writei(pcm, out_buf, nsamp)
                    frames_played = frames_played + 1
                    total_samples = total_samples + nsamp
                    if frames_played <= 3 or frames_played % 40 == 0 then
                        out(string.format("  frame %3d: %d samples, writei=%d", frames_played, nsamp, tonumber(wrote) or -999))
                    end
                end
                lib.av_frame_unref(frame)
            end
        end

        out(string.format("frames played: %d", frames_played))
        out(string.format("total samples: %d (%.1f seconds at %d Hz)",
            total_samples, total_samples / in_sample_rate, in_sample_rate))

        -- Drain and cleanup
        section("6. CLEANUP")
        out("draining ALSA ('" .. alsa_device .. "')...")
        lib.snd_pcm_drain(pcm)
        lib.snd_pcm_close(pcm)
        out("ALSA closed")

        lib.swr_free(ffi.new("struct SwrContext*[1]", {swr2}))
        lib.av_frame_free(ffi.new("struct AVFrame*[1]", {frame}))
        lib.av_packet_free(ffi.new("struct AVPacket*[1]", {pkt}))
        lib.avcodec_free_context(ffi.new("struct AVCodecContext*[1]", {ctx}))
        lib.avformat_close_input(fmt_ctx_ptr)
        out("cleanup done")

        section("7. VERDICT")
        if frames_played > 0 then
            out(string.format("SUCCESS: %d frames decoded and pushed to ALSA '%s'.",
                frames_played, alsa_device))
            out("If you heard audio: the full pipeline works!")
            out("If you heard nothing: check ALSA device / volume.")
        else
            out("FAILURE: no frames were played.")
        end

        return write_report()
    end

    local ok, result = xpcall(body, function(e)
        return tostring(e) .. "\n" .. debug.traceback()
    end)
    if ok then
        return result
    end
    out("")
    out("==== PROBE CRASHED (uncaught Lua error) ====")
    out(tostring(result))
    return write_report()
end

return audio_probe
