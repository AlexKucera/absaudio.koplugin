# Issue #39 — Audio Slice D: TDD Plan

> **Parent PRD:** #31 (In-App Audio Playback, FFmpeg + ALSA, Path C)
> **Parent issue:** #34 (Audio slice C — first audible playback)
> **Slice:** D — port the confirmed FFmpeg/ALSA pipeline into `ffmpeg_backend`
> **Reference implementation:** `audio_probe.run_play_test` (proved audible playback)

## Why this slice is split: testable vs device-only

The real FFmpeg decode loop + ALSA `snd_pcm_writei` call symbols that do not
exist on the dev Mac (the lib never loads). So:

- **Off-device testable (real TDD):** the FFI struct layouts. LuaJIT computes
  `ffi.offsetof` from declared cdefs WITHOUT loading any library. We declare
  the full FFmpeg 6.0 structs with the on-device-verified offsets and assert
  each named field lands where the probe confirmed. This is the bulk of the
  verifiable work.
- **Device-only (written, not unit-tested):** `audio_device.create_decoder`
  (FFmpeg decode loop), `audio_device.create_alsa_sink` (`snd_pcm_writei`), and
  the `ffmpeg_backend.play()` wiring. These mirror the proven
  `audio_probe.run_play_test` exactly. Off-device we only verify they **load**
  without error (`luajit -e "require(...)"`); real verification is by ear on the
  PB700K3 (HITL).

## Module design

New module **`absaudio/audio_device.lua`** owns the real device glue:
- `audio_device.create_decoder(path)` → decoder (`read_frame()`→`{pcm,pts_ms}`,
  `close()`). Mirrors the probe decode loop: open → find_stream → open_codec →
  swr setup (FLTP→S16), per frame: read_frame → send_packet → receive_frame →
  swr_convert → return S16 bytes + `time_math.to_ms(pts, time_base)`.
- `audio_device.create_alsa_sink()` → `{write(data,n), close()}`. First write
  opens `"plughw:0,0"` + `snd_pcm_set_params(S16_LE, RW_INTERLEAVED)`.
- `audio_device.create_schedule()` → `UIManager:scheduleIn` wrapper.

`audio_ffi.lua` keeps its role (FFI declaration + availability probe) but:
- Opaque forward declarations → **full FFmpeg 6.0 struct layouts** with verified
  field offsets (char-array padding for gaps, `ffi.offsetof`-tested).
- Adds **all** FFmpeg/ALSA function signatures from the probe.
- Adds `audio_ffi.get_lib()` — memoized guarded `ffi.load` + cdef ensure;
  returns the lib handle or nil. `audio_device` uses this.

`ffmpeg_backend.lua` change: when `is_available()` AND no explicit injected
`decoder_factory`/`sink`, `play()` builds real ones from `audio_device`.
CLOCK mode (no factory) and all injected-mock tests stay byte-for-byte unchanged.

## Confirmed FFmpeg 6.0 struct offsets (64-bit ARM — source of truth)

From on-device memory dumps (see
`docs/devlog/20260614-issue34-audio-playback-ffmpeg-alsa-audible-success_log.md`):

| Struct | Field | Offset | Notes |
|--------|-------|--------|-------|
| AVFormatContext | nb_streams | 44 | unsigned int |
| AVFormatContext | streams | 48 | AVStream** |
| AVCodecParameters | codec_type | 0 | AVMEDIA_TYPE_AUDIO=1 |
| AVCodecParameters | codec_id | 4 | AAC=86018 |
| AVCodecParameters | codec_tag | 8 | uint32 |
| AVCodecParameters | channel_layout | 96 | uint64, STEREO=3 |
| AVCodecParameters | channels | 104 | int |
| AVCodecParameters | sample_rate | 108 | int |
| AVCodecParameters | frame_size | 116 | int (AAC=1024) |
| AVCodecContext | time_base | 76 | AVRational {num@76, den@80} |
| AVCodecContext | sample_rate | 304 | int |
| AVCodecContext | channels | 308 | int |
| AVCodecContext | sample_fmt | 312 | int (FLTP=8) |
| AVCodecContext | frame_size | 316 | int |
| AVCodecContext | channel_layout | 336 | uint64 |
| AVFrame | data[0..1] | 0, 8 | uint8_t* per plane (FLTP: L@0, R@8) |
| AVFrame | linesize[0] | 64 | int |
| AVFrame | nb_samples | 112 | int |
| AVFrame | format | 116 | int (FLTP=8) |
| AVFrame | sample_rate | 168 | int (**NOT 256**) |
| AVFrame | pts | 192 | int64_t |
| AVStream | codecpar | 16 | AVCodecParameters* |
| AVStream | time_base | 24 | AVRational {num@24, den@28} |

ALSA: device `"plughw:0,0"`, `SND_PCM_FORMAT_S16_LE = 2`,
`SND_PCM_ACCESS_RW_INTERLEAVED = 3`.

## Scenarios (BDD bridge — off-device slices)

From PRD #31 user stories 1, 6, 7, 26:

1. **AVFrame field offsets match the device probe** (US 1): Given the cdef is
   declared, when `ffi.offsetof("struct AVFrame", "pts")` is read, then it
   returns 192 (and data@0, nb_samples@112, format@116, sample_rate@168).
2. **AVCodecParameters field offsets match the probe** (US 1): Given the cdef,
   when offsets are read, then codec_type@0, codec_id@4, channel_layout@96,
   channels@104, sample_rate@108, frame_size@116.
3. **AVFormatContext + AVStream offsets match the probe** (US 1): nb_streams@44,
   streams@48; AVStream codecpar@16, time_base@24.
4. **AVCodecContext offsets match the probe** (US 1): time_base@76, sample_rate@304,
   channels@308, sample_fmt@312, frame_size@316, channel_layout@336.
5. **is_available() stays false on dev with expanded cdefs** (US 26): the full
   structs + all functions declare without error but the lib still does not load
   → false (unchanged).
6. **audio_device loads without error** (US 1): `require("absaudio/audio_device")`
   succeeds; no LuaJIT syntax error, no invalid escape sequences.
7. **ffmpeg_backend falls back to CLOCK/stub when not available** (US 26): with
   `is_available()` false, `play()` uses clock mode (existing 45 tests green).

## Device handoff checklist (HITL — NOT this session)

- [ ] `audio_ffi.is_available()` returns **true** on PB700K3 (libaudio-engine +
      all KEY_SYMBOLS resolve with the expanded cdefs).
- [ ] `audio_device.create_decoder(path)` opens a downloaded M4B and
      `read_frame()` returns S16 PCM bytes with advancing PTS.
- [ ] `audio_device.create_alsa_sink()` opens `plughw:0,0`; playback is audible.
- [ ] `ffmpeg_backend` (auto-detect) plays a short M4B end-to-end (audible,
      position advances, stop tears down cleanly).
- [ ] Wake-lock held during playback, released on stop.

## Acceptance criteria status (issue #39)

- [ ] audio_ffi declares full struct layouts + all function sigs — **off-device**
- [ ] ffi.offsetof tests confirm offsets match probe — **off-device TDD**
- [ ] is_available() false on dev (unchanged) — **off-device**
- [ ] Real decoder_factory (mirrors probe) — **off-device written, device-verified**
- [ ] Real ALSA sink — **off-device written, device-verified**
- [ ] ffmpeg_backend.play() wires real when available, stub otherwise — **off-device (fallback path tested; real path device-verified)**
- [ ] All 45 ffmpeg_backend + producer/pump tests pass (mock factories unchanged) — **off-device**
- [ ] No LuaJIT syntax errors / invalid escapes — **off-device**
- [ ] All cdefs pcall-guarded — **off-device**
- [ ] Full test suite passes — **off-device**
