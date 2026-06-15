-- audio_ffi: guarded FFI shim for the FFmpeg+ALSA audio backend (issue #34, slice C)
--
-- Declares the FFmpeg/ALSA C signatures (cdefs) GUARDED inside pcall so a
-- redeclaration or missing symbol never crashes, and implements the REAL
-- is_available() capability probe: dlopen libaudio-engine + verify that all
-- KEY_SYMBOLS resolve. On the dev Mac the lib does not load → returns false.
--
-- ALL FFI access is pcall-guarded (lesson from the IsPlayingMP3 probe crash):
--   - ffi.cdef blocks: wrapped in pcall (LuaJIT ERRORS on redeclaration)
--   - ffi.load: wrapped in pcall (missing .so errors, doesn't crash)
--   - lib[symbol] lookups: wrapped in pcall (the lookup itself throws
--     "undefined symbol" for symbols absent from THIS firmware build)
-- A missing library or symbol is a graceful false, NEVER a crash.
--
-- The real decode bodies (avformat_open_input → av_read_frame → decode →
-- swr_convert → PCM) are filled in the device session; this module only
-- declares the signatures and performs the capability check.
--
-- Public API:
--   audio_ffi.is_available() -> bool   guarded dlopen + key-symbol check; memoized; false on dev
--   audio_ffi._set_probe_override(fn|nil)  test hook; nil restores the default probe
--   audio_ffi.KEY_SYMBOLS -> table     read-only array of FFmpeg symbols checked

local audio_ffi = {}

-- The FFmpeg symbols that must all resolve for the backend to be "available".
-- Confirmed exported by libaudio-engine.so in the v4 device probe
-- (see docs/devlog/20260614-decision-audio-backend-path-c-ffmpeg_log.md).
audio_ffi.KEY_SYMBOLS = {
    "avformat_open_input",
    "av_read_frame",
    "avcodec_send_packet",
    "avcodec_receive_frame",
    "swr_init",
}

------------------------------------------------------------------------
-- Declare cdefs GUARDED: pcall swallows LuaJIT's error on redeclaration
-- (it errors even for identical signatures). Incomplete (forward-declared)
-- structs avoid blind-layout risk — we only need opaque pointers.
------------------------------------------------------------------------
local function declare_cdefs(ffi)
    -- FFmpeg format/codec cdefs
    pcall(ffi.cdef, [[
        struct AVFormatContext;
        struct AVCodecContext;
        struct AVFrame;
        struct AVPacket;
        struct SwrContext;
        struct AVRational { int num; int den; };

        int avformat_open_input(struct AVFormatContext **ps, const char *url,
                                const void *fmt, void **options);
        int avformat_find_stream_info(struct AVFormatContext *ic, void **options);
        void avformat_close_input(struct AVFormatContext **s);

        int av_read_frame(struct AVFormatContext *s, struct AVPacket *pkt);

        const void *avcodec_find_decoder(int codec_id);
        int avcodec_open2(struct AVCodecContext *avctx, const void *codec,
                          void **options);
        int avcodec_send_packet(struct AVCodecContext *avctx,
                                const struct AVPacket *avpkt);
        int avcodec_receive_frame(struct AVCodecContext *avctx,
                                  struct AVFrame *frame);

        struct SwrContext *swr_alloc(void);
        int swr_init(struct SwrContext *s);
        int swr_convert(struct SwrContext *s, uint8_t **out, int out_count,
                        const uint8_t **in, int in_count);
        void swr_free(struct SwrContext **s);
    ]])

    -- ALSA write path (used by the output pump; real wiring in the device session)
    pcall(ffi.cdef, [[
        int snd_pcm_writei(void *handle, const void *data, unsigned long frames);
    ]])
end

------------------------------------------------------------------------
-- Default is_available() probe (memoized): guarded FFI load of the PocketBook
-- audio toolkit + key-symbol validation. Returns true only if libaudio-engine
-- loads AND every KEY_SYMBOL resolves. False on the dev Mac.
------------------------------------------------------------------------
local default_probe
do
    local probed = false
    local available = false

    default_probe = function()
        if probed then return available end
        probed = true

        local ok_ffi, ffi = pcall(require, "ffi")
        if not ok_ffi then
            available = false
            return false
        end

        -- Declare cdefs (guarded — safe even if already declared)
        declare_cdefs(ffi)

        -- Guarded library load: missing .so errors, doesn't crash
        local lib_ok, lib = pcall(ffi.load, "audio-engine")
        if not lib_ok then
            available = false
            return false
        end

        -- Verify every key symbol resolves. The lib[sym] lookup itself can
        -- throw "undefined symbol" — wrap it in pcall.
        for _, sym in ipairs(audio_ffi.KEY_SYMBOLS) do
            local sym_ok = pcall(function() return lib[sym] end)
            if not sym_ok then
                available = false
                return false
            end
        end

        available = true
        return true
    end
end

-- Module-level probe override (for tests / forced device mode).
local probe_override = nil

------------------------------------------------------------------------
-- Whether the FFmpeg backend can run in the current environment.
-- False on the dev Mac; true on a PocketBook once libaudio-engine.so loads
-- and all KEY_SYMBOLS resolve. NEVER crashes.
-- Mockable: audio_ffi._set_probe_override(fn) overrides the default probe.
-- @return bool
------------------------------------------------------------------------
function audio_ffi.is_available()
    if probe_override then return probe_override() end
    return default_probe()
end

-- Test-only: override the module-level availability probe.
-- @param fn function|nil  fn() -> bool overrides; nil restores the default probe
function audio_ffi._set_probe_override(fn)
    probe_override = fn
end

return audio_ffi
