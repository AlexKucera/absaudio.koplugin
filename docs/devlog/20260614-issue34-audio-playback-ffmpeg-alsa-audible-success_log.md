# Issue #34 — Audible M4B Playback via FFmpeg + ALSA Confirmed

> **Date:** 2026-06-14
> **Type:** issue (milestone)
> **Reference:** Issue #34 — First audible playback: decode M4B via FFmpeg + output via ALSA

## Goal

Verify — on the real PocketBook PB700K3 device — that the in-app audio playback
backend can actually decode an M4B file and produce **audible sound**. This is
the Human-In-The-Loop gate for Issue #34 (Slice C). All prior work (slices A/B/C)
built the off-device control-flow layer with mocked FFI; this session confirmed
the real device path end-to-end.

## What Was Done

- **Decode layout probe** (`audio_probe.run_decode_layout_probe`): opens a real
  downloaded M4B, decodes one AAC frame, and dumps the actual field
  offsets/values for every FFmpeg 6.0 struct (`AVFormatContext`,
  `AVCodecParameters`, `AVCodecContext`, `AVFrame`, `AVStream`).
- **Codec context dump** (Section 6): raw int32 dump of `AVCodecContext` after
  `avcodec_open2`, cross-verified by scanning for known values (sample_rate,
  time_base).
- **Play-test probe** (`audio_probe.run_play_test`): minimal standalone pipeline
  that decodes ~5 seconds of audio, converts FLTP→S16 via `swr_convert`, and
  writes to ALSA via `snd_pcm_writei`. **Produces audible sound.**
- **ALSA hardware enumeration** (Section 0.5): reads `/proc/asound/cards`,
  `/proc/asound/pcm`, `/proc/asound/devices`, and lists `/dev/snd/` to discover
  the real audio hardware.
- **Menu wiring**: two new menu items + handlers in `main.lua` ("Audio decode
  layout probe" and "Audio play-test").
- All report files written **incrementally** (flush every line) so native
  crashes (SIGSEGV) preserve output up to the crash point.

## Confirmed FFmpeg 6.0 Struct Offsets (64-bit ARM)

These are verified by actual on-device memory dumps, not documentation:

| Struct | Field | Offset | Value | Notes |
|--------|-------|--------|-------|-------|
| AVFormatContext | nb_streams | 44 | 3 | |
| AVFormatContext | streams | 48 | ptr | |
| AVCodecParameters | codec_type | 0 | 1 | AVMEDIA_TYPE_AUDIO |
| AVCodecParameters | codec_id | 4 | 86018 | AAC |
| AVCodecParameters | codec_tag | 8 | "mp4a" | |
| AVCodecParameters | channel_layout | 96 | 3 | STEREO |
| AVCodecParameters | channels | 104 | 2 | |
| AVCodecParameters | sample_rate | 108 | 22050 | |
| AVCodecParameters | frame_size | 116 | 1024 | AAC frame |
| AVCodecContext | time_base | 76-80 | {1, 22050} | num@76, den@80 |
| AVCodecContext | sample_rate | 304 | 22050 | |
| AVCodecContext | channels | 308 | 2 | |
| AVCodecContext | sample_fmt | 312 | 8 | FLTP |
| AVCodecContext | frame_size | 316 | 1024 | |
| AVCodecContext | channel_layout | 336 | 3 | STEREO |
| AVFrame | data[0] | 0 | ptr | L channel floats |
| AVFrame | data[1] | 8 | ptr | R channel floats |
| AVFrame | linesize[0] | 64 | 8192 | |
| AVFrame | nb_samples | 112 | 1024 | |
| AVFrame | format | 116 | 8 | FLTP |
| AVFrame | sample_rate | 168 | 22050 | **NOT 256 as docs claim** |
| AVFrame | pts | 192 | 0 | first frame |

## Confirmed ALSA Device: `plughw:0,0`

Hardware (from `/proc/asound/cards`):
- **Card 0: `audiocodec` (SUNXI-CODEC — AllWinner SoC audio)** — physical DAC
  - `hw:0,0` / `plughw:0,0`: codec-aif1 — **main speaker output (WORKS)**
  - `hw:0,1`: bb Voice (baseband)
  - `hw:0,2`: bb-bt-clk (BT clock)
  - `hw:0,3`: bt Voice (BT voice)
- **Card 1: `Loopback`** — virtual, produces no sound

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Use raw ALSA `snd_pcm_*` (not audio-engine `open_alsa`/`push_output_buffer`) | audio-engine `open_alsa('tts_sm')` returned `0x1` (a status code, not a pointer) → `push_output_buffer` got a bogus handle. Raw ALSA bypasses this broken wrapper. |
| Use `plughw:0,0` as the output device | The original design chose `tts_sm` to "avoid amplifier corruption," but `tts_sm` is a **virtual device** (not in `/proc/asound/pcm`) that silently swallows audio. `plughw:0,0` is the real SUNXI-CODEC DAC and produces audible sound. The amplifier-corruption concern was about the inkview API; raw ALSA bypasses inkview. |
| Convert FLTP→S16 via `swr_convert` | AAC decodes to FLTP (planar float: `data[0]`=L, `data[1]`=R). ALSA needs S16 interleaved. `swr_convert` handles this in one call. |
| Incremental report file writes (flush every line) | Native SIGSEGV crashes (from bad pointer derefs or missing cdefs) kill the process instantly — `xpcall` cannot catch them. Flushing every line ensures the report captures everything up to the crash point. |
| Probe struct offsets on-device before writing real decode code | FFmpeg 6.0 changed `channel_layout` to `AVChannelLayout` and many documented offsets (e.g. `AVFrame.sample_rate` is at 168, not 256). Wrong offsets = segfault. The probe verified every offset against real memory before integration. |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| No InfoMessage, no report on first decode probe run | 22 invalid `\u2014`/`\u2192`/`\u2190` Unicode escapes in string literals. LuaJIT (Lua 5.1) doesn't support `\u` escapes → module couldn't compile → `require()` failed. | Replaced all with ASCII (`-`, `->`, `<-`). |
| `find_test_m4b` crash: "directory metatable expected, got nil" | `pcall(lfs.dir, dir)` on PocketBook captures only the first return value (the generator), discarding the 3-tuple `(gen, state, control)`. The `for` loop then called `gen(nil, nil)`. | Check dir existence with `lfs.attributes(dir, "mode")` first, then iterate `lfs.dir(dir)` directly (no pcall wrapper). |
| `missing declaration for symbol 'avformat_open_input'` | DECODE_CDEFS declared structs but not the 14 FFmpeg functions the probe calls. | Added all 14 function declarations to the cdef block. |
| FFI type error in `free()` calls | `ffi.new("struct AVFrame**[1]", {frame})` — can't initialize a `**` element with a `*` value. | Changed to `*[1]` (array of pointers decays to `**` when passed to C). |
| 30-second hang then silent crash (no report) | Blind pointer dereference scans: read random 8-byte values from struct memory and treated them as pointers → dereferencing non-pointer values (like `duration`) → SIGSEGV. `xpcall` can't catch native crashes, and report was only written at the end. | (1) Incremental file writes (flush every line). (2) Replaced ALL blind pointer derefs with struct field access at verified FFmpeg 6.0 offsets. |
| Wrong struct offsets (AVStream/AVFormatContext) | AVStream had a phantom `internal` field pushing `codecpar` to offset 24 (should be 16); AVFormatContext had no `streams` pointer field. | Rebuilt structs with correct FFmpeg 6.0 layouts; verified with `ffi.offsetof`. |
| `AVFrame.sample_rate` at wrong offset | Documentation said offset 256; actual offset is 168. | Cross-verify scan (search frame bytes for the 22050 value) found it at 168. |
| Probe ran to completion but no sound | `tts_sm` is a virtual ALSA device (not in `/proc/asound/pcm`) that accepts data silently. | Hardware enumeration revealed real DAC (`audiocodec`/SUNXI-CODEC). Switched to `plughw:0,0`. |
| InfoMessage dismissed after ~1 second | `timeout = 0` doesn't mean "forever" on this KOReader build. | Changed to `timeout = 60`. |

## Files Changed

| File | Change Summary |
|------|----------------|
| `absaudio/audio_probe.lua` | `run_decode_layout_probe()`: struct offset verification (8 sections). `run_play_test()`: full decode+resample+ALSA play pipeline (7 sections). `find_test_m4b()`: pcall-guarded, PocketBook lfs.dir fix. `DECODE_CDEFS`: fixed AVStream/AVFormatContext structs, added all FFmpeg function declarations. `PLAY_CDEFS`: swresample + ALSA + audio-engine cdefs. Hardware enumeration section. |
| `main.lua` | 2 new menu items (decode probe, play-test) + handlers (`onRunAudioDecodeProbe`, `onRunAudioPlayTest`). `timeout: 0` → `60` on all probe handlers. |
| `spec/test_main.lua` | Menu sub-item count assertion 4 → 6. |

## Open Items & Next Steps

- [ ] **Integrate the confirmed pipeline into `ffmpeg_backend`** — wire real FFmpeg decode + `swr_convert` (FLTP→S16) + `snd_pcm_writei`(`plughw:0,0`) into the existing `decoder_factory`, output sink, and player wiring. This completes Issue #34's HITL core.
- [ ] **Position tracking** — use `AVFrame.pts` (offset 192) with time_base `{1, sample_rate}` for real PTS-driven playback position (the PRODUCER mode in the dual position-source design).
- [ ] **Wake-lock verification** — confirm the firmware sleep-ban prevents suspend-stall during playback.
- [ ] **Volume control** — wire `snd_pcm_set_volume` or mixer controls.
- [ ] **Probe cleanup** — the probe menu items are diagnostic scaffolding; decide whether to keep them hidden behind a debug flag or remove after integration.
- [ ] **Atempo/speed** — wire the atempo filter-chain builder (slice A) for playback speed control in the real decode path.

---

*Log written by write-log skill*
