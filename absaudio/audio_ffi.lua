-- audio_ffi: guarded FFI shim for the FFmpeg+ALSA audio backend
-- (issues #33/#34 skeleton, #39 full struct layouts + device glue seam)
--
-- Declares the FFmpeg 6.0 struct layouts (full, with on-device-verified field
-- offsets) and the FFmpeg/ALSA C function signatures (cdefs) GUARDED inside
-- pcall so a redeclaration or missing symbol never crashes. Implements the REAL
-- is_available() capability probe: dlopen libaudio-engine + verify that all
-- KEY_SYMBOLS resolve. On the dev Mac the lib does not load -> returns false.
--
-- Struct offsets are the SOURCE OF TRUTH from the on-device decode layout probe
-- (docs/devlog/20260614-issue34-audio-playback-ffmpeg-alsa-audible-success_log.md).
-- They are asserted by spec/test_audio_ffi.lua via ffi.offsetof. Gaps between
-- the named fields we use are bridged with char-array padding (1-byte aligned,
-- so it never disturbs the natural alignment of the fields that follow).
--
-- ALL FFI access is pcall-guarded (lesson from the IsPlayingMP3 probe crash):
--   - ffi.cdef blocks: wrapped in pcall (LuaJIT ERRORS on redeclaration)
--   - ffi.load: wrapped in pcall (missing .so errors, doesn't crash)
--   - lib[symbol] lookups: wrapped in pcall (the lookup itself throws
--     "undefined symbol" for symbols absent from THIS firmware build)
-- A missing library or symbol is a graceful false, NEVER a crash.
--
-- Public API:
--   audio_ffi.is_available() -> bool        guarded dlopen + key-symbol check; memoized; false on dev
--   audio_ffi.get_lib()      -> lib|nil     memoized guarded load + cdef ensure (nil if unavailable)
--   audio_ffi.declare_cdefs(ffi)            idempotent guarded cdef declaration (used by audio_device)
--   audio_ffi._set_probe_override(fn|nil)   test hook; nil restores the default probe
--   audio_ffi.KEY_SYMBOLS -> table          read-only array of FFmpeg+ALSA symbols checked

local audio_ffi = {}

------------------------------------------------------------------------
-- The FFmpeg + ALSA symbols that must ALL resolve for the backend to be
-- "available". Confirmed exported by libaudio-engine.so on the PB700K3
-- (docs/devlog/20260614-decision-audio-backend-path-c-ffmpeg_log.md).
-- Spans every pipeline stage (container, codec, resample, ALSA output) so a
-- true result proves the full decode+play path is present.
------------------------------------------------------------------------
audio_ffi.KEY_SYMBOLS = {
    -- container / demux
    "avformat_open_input",
    "avformat_find_stream_info",
    "av_read_frame",
    "avformat_close_input",
    "av_find_best_stream",
    -- codec
    "avcodec_find_decoder",
    "avcodec_alloc_context3",
    "avcodec_parameters_to_context",
    "avcodec_open2",
    "avcodec_send_packet",
    "avcodec_receive_frame",
    -- packet / frame alloc
    "av_packet_alloc",
    "av_frame_alloc",
    -- resample (FLTP -> S16)
    "swr_alloc",
    "swr_alloc_set_opts",
    "swr_init",
    "swr_convert",
    -- ALSA output (plughw:0,0)
    "snd_pcm_open",
    "snd_pcm_set_params",
    "snd_pcm_writei",
    "snd_pcm_drain",
    "snd_pcm_close",
    "snd_pcm_prepare",
    "snd_pcm_resume",
    "snd_strerror",
}

------------------------------------------------------------------------
-- FFmpeg 6.0 struct layouts (64-bit ARM) + function signatures.
-- Guarded: pcall swallows LuaJIT's error on redeclaration (it errors even for
-- identical signatures). Fields we never field-access (AVCodec, AVPacket) stay
-- opaque forward declarations; the structs we DO field-access are laid out with
-- the verified offsets and char-array padding for the gaps between them.
--
-- Offset table (verified on-device, asserted in test_audio_ffi.lua):
--   AVFormatContext: nb_streams@44, streams@48
--   AVCodecParameters: codec_type@0, codec_id@4, codec_tag@8,
--                      channel_layout@96, channels@104, sample_rate@108, frame_size@116
--   AVCodecContext: time_base@76, sample_rate@304, channels@308,
--                   sample_fmt@312, frame_size@316, channel_layout@336
--   AVFrame: data@0, linesize@64, nb_samples@112, format@116,
--            sample_rate@168 (NOT 256), pts@192
--   AVStream: codecpar@16, time_base@24
------------------------------------------------------------------------
local FFMPEG_CDEFS = [[
    struct AVRational { int num; int den; };

    /* AVFormatContext (FFmpeg 6.0, 64-bit): nb_streams@44, streams@48, duration@72 */
    struct AVFormatContext {
        void *av_class;                     /*   0 */
        void *iformat;                      /*   8 */
        void *oformat;                      /*  16 */
        void *priv_data;                    /*  24 */
        void *pb;                           /*  32: AVIOContext* */
        int ctx_flags;                      /*  40 */
        unsigned int nb_streams;            /*  44: KEY */
        struct AVStream **streams;          /*  48: KEY */
        char *url;                          /*  56 */
        int64_t start_time;                 /*  64: UNVERIFIED on-device (0=unknown) */
        int64_t duration;                   /*  72: UNVERIFIED on-device, AV_TIME_BASE=us (0=unknown) */
        char _rest_fmt[1];                  /*   opaque tail (rest of struct) */
    };

    /* AVStream (FFmpeg 6.0, 64-bit): codecpar@16, time_base@24 */
    struct AVStream {
        int index;                          /*   0 */
        int id;                             /*   4 */
        void *priv_data;                    /*   8 */
        struct AVCodecParameters *codecpar; /*  16: KEY */
        struct AVRational time_base;        /*  24: {num@24, den@28} KEY */
        char _rest_stream[1];               /*   opaque tail */
    };

    /* AVCodecParameters: only the fields we read for swr/ALSA setup */
    struct AVCodecParameters {
        int codec_type;                     /*   0: AVMEDIA_TYPE_AUDIO = 1 */
        int codec_id;                       /*   4: AVCodecID (AAC = 86018) */
        uint32_t codec_tag;                 /*   8: e.g. "mp4a" */
        char _gap_cp1[84];                  /*  12 -> 96 */
        uint64_t channel_layout;            /*  96: AV_CH_LAYOUT_* (STEREO = 3) */
        int channels;                       /* 104 */
        int sample_rate;                    /* 108 */
        int _gap_cp2;                       /* 112 */
        int frame_size;                     /* 116: AAC = 1024 */
        char _rest_cp[1];                   /*   opaque tail */
    };

    /* AVCodecContext: accessed only at verified offsets for verification.
       We never read these by name in the decode loop (params come from
       codecpar), but the offsets are declared + asserted for completeness. */
    struct AVCodecContext {
        char _gap_cc1[76];                  /*   0 ->  76 */
        struct AVRational time_base;        /*  76: {num@76, den@80} */
        char _gap_cc2[220];                 /*  84 -> 304 */
        int sample_rate;                    /* 304 */
        int channels;                       /* 308 */
        int sample_fmt;                     /* 312: AVSampleFormat (FLTP = 8) */
        int frame_size;                     /* 316 */
        char _gap_cc3[16];                  /* 320 -> 336 */
        uint64_t channel_layout;            /* 336 */
        char _rest_cc[1];                   /*   opaque tail */
    };

    /* AVFrame: data planes, sample count, format, PTS. FLTP decode gives
       data[0]=L channel, data[1]=R channel. sample_rate is at 168 (NOT 256). */
    struct AVFrame {
        uint8_t *data[8];                   /*   0: data planes (data[0]@0, data[1]@8) */
        int linesize[8];                    /*  64: line sizes (linesize[0]@64) */
        uint8_t *extended_data;             /*  96 */
        int width;                          /* 104 */
        int height;                         /* 108 */
        int nb_samples;                     /* 112: samples per channel */
        int format;                         /* 116: AVSampleFormat */
        char _gap_fr1[48];                  /* 120 -> 168 */
        int sample_rate;                    /* 168: KEY (NOT 256) */
        char _gap_fr2[20];                  /* 172 -> 192 */
        int64_t pts;                        /* 192: presentation timestamp */
        char _rest_fr[1];                   /*   opaque tail */
    };

    /* Opaque types we only ever pass as pointers to FFmpeg API functions */
    struct AVCodec;                         /* found via avcodec_find_decoder */
    struct AVPacket;                        /* alloc'd by av_packet_alloc */

    /* ---- FFmpeg container / demux ---- */
    int avformat_open_input(struct AVFormatContext **ps, const char *url,
                            const void *fmt, void **options);
    int avformat_find_stream_info(struct AVFormatContext *ic, void **options);
    int av_read_frame(struct AVFormatContext *s, struct AVPacket *pkt);
    void avformat_close_input(struct AVFormatContext **s);
    int av_find_best_stream(struct AVFormatContext *ic, int type,
                            int wanted_stream, int related_stream,
                            const struct AVCodec **decoder_ret, int flags);

    /* ---- FFmpeg codec ---- */
    const struct AVCodec *avcodec_find_decoder(int codec_id);
    struct AVCodecContext *avcodec_alloc_context3(const struct AVCodec *codec);
    int avcodec_parameters_to_context(struct AVCodecContext *codec,
                                      const struct AVCodecParameters *par);
    int avcodec_open2(struct AVCodecContext *avctx, const struct AVCodec *codec,
                      void **options);
    void avcodec_free_context(struct AVCodecContext **avctx);
    int avcodec_send_packet(struct AVCodecContext *avctx,
                            const struct AVPacket *avpkt);
    int avcodec_receive_frame(struct AVCodecContext *avctx,
                              struct AVFrame *frame);

    /* ---- FFmpeg packet / frame lifecycle ---- */
    struct AVPacket *av_packet_alloc(void);
    void av_packet_unref(struct AVPacket *pkt);
    void av_packet_free(struct AVPacket **pkt);
    struct AVFrame *av_frame_alloc(void);
    void av_frame_unref(struct AVFrame *frame);
    void av_frame_free(struct AVFrame **frame);
]]

local SWR_CDEFS = [[
    struct SwrContext;
    struct SwrContext *swr_alloc(void);
    struct SwrContext *swr_alloc_set_opts(struct SwrContext *s,
        long long out_ch_layout, int out_sample_fmt, int out_sample_rate,
        long long in_ch_layout,  int in_sample_fmt, int in_sample_rate,
        int log_level_offset, void *log_ctx);
    int swr_init(struct SwrContext *s);
    int swr_convert(struct SwrContext *s, uint8_t **out, int out_count,
                    const uint8_t **in, int in_count);
    void swr_free(struct SwrContext **s);
]]

local ALSA_CDEFS = [[
    typedef struct _snd_pcm snd_pcm_t;
    int snd_pcm_open(snd_pcm_t **pcm, const char *name, int stream, int mode);
    int snd_pcm_set_params(snd_pcm_t *pcm, int format, int access,
                           unsigned int channels, unsigned int rate,
                           int soft_resample, unsigned int latency);
    long snd_pcm_writei(snd_pcm_t *pcm, const void *buffer, unsigned long size);
    int snd_pcm_prepare(snd_pcm_t *pcm);
    int snd_pcm_resume(snd_pcm_t *pcm);
    int snd_pcm_drain(snd_pcm_t *pcm);
    int snd_pcm_close(snd_pcm_t *pcm);
    const char *snd_strerror(int err);
]]

-- Idempotent: declare all cdefs guarded (safe even if already declared).
-- Exposed so audio_device.lua can ensure cdefs before using the types.
function audio_ffi.declare_cdefs(ffi)
    pcall(ffi.cdef, FFMPEG_CDEFS)
    pcall(ffi.cdef, SWR_CDEFS)
    pcall(ffi.cdef, ALSA_CDEFS)
end

------------------------------------------------------------------------
-- Memoized guarded load: declare cdefs, guardedly ffi.load libaudio-engine,
-- and return the lib handle (or nil if it cannot load). Used by audio_device
-- to obtain the real FFmpeg/ALSA function table.
------------------------------------------------------------------------
local _lib_cache  -- nil = not yet probed; false = load failed; table = lib handle
function audio_ffi.get_lib()
    if _lib_cache ~= nil then
        return _lib_cache or nil  -- false -> nil for callers
    end
    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi then _lib_cache = false; return nil end

    audio_ffi.declare_cdefs(ffi)

    local lib_ok, lib = pcall(ffi.load, "audio-engine")
    if not lib_ok then
        _lib_cache = false
        return nil
    end
    _lib_cache = lib
    return lib
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

        local lib = audio_ffi.get_lib()
        if not lib then
            available = false
            return false
        end

        -- Verify every key symbol resolves. The lib[sym] lookup itself can
        -- throw "undefined symbol" -- wrap it in pcall.
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
-- Delegates to get_lib() + KEY_SYMBOLS check. False on the dev Mac; true on a
-- PocketBook once libaudio-engine.so loads and all KEY_SYMBOLS resolve.
-- NEVER crashes.
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

-- Test-only: inject a fake lib table (or nil to restore default probing).
-- Lets off-device tests exercise create_alsa_sink / create_decoder paths that
-- otherwise bail at get_lib(). Mirrors _set_probe_override.
function audio_ffi._set_lib_for_testing(lib)
    _lib_cache = lib
end

return audio_ffi
