# Issue #39 — Audio Slice D: Real FFmpeg/ALSA Glue + Backend Wiring

> **Date:** 2026-06-15
> **Type:** issue
> **Reference:** GitHub issue #39 — "Audio slice D: Port confirmed FFmpeg/ALSA pipeline into the backend". Parent PRD #31, parent issue #34 (slice C control-flow layer). TDD plan: `docs/devlog/issue39-tdd-plan.md`.

## Goal

Port the on-device-confirmed FFmpeg decode + ALSA output pipeline (proven audible by `audio_probe.run_play_test`) into the audio backend's injectable seams, completing the off-device-testable portion of issue #39. Two parts: (1) expand `audio_ffi.lua` to full FFmpeg 6.0 struct layouts + all function signatures, verified by `ffi.offsetof` tests; (2) write `audio_device.lua` as the real device glue behind slice C's decoder/sink/schedule seams, and wire `ffmpeg_backend` to auto-detect it on-device. The real decode/output paths are HITL device-only — off-device we verify graceful degradation and the API shapes the rest of the pipeline depends on.

## What Was Done

### Phase 1: `audio_ffi.lua` — full struct layouts + function signatures (COMPLETE)
- Declared **full FFmpeg 6.0 struct layouts**: AVFormatContext, AVStream, AVCodecParameters, AVCodecContext, AVFrame, AVRational — with on-device-verified field offsets from the decode layout probe (`docs/devlog/20260614-issue34-audio-playback-ffmpeg-alsa-audible-success_log.md`). Gaps between named fields bridged with char-array padding (1-byte aligned) to preserve natural alignment.
- Added **all FFmpeg/ALSA/swresample function signatures** from the probe's cdefs, all pcall-guarded.
- Added **`get_lib()`**: memoized guarded `ffi.load` + cdef ensure, returns lib handle or nil. `audio_device` uses this.
- Added **`start_time`@64 + `duration`@72** to AVFormatContext (FFmpeg 6.0 standard layout, UNVERIFIED on-device — reading an int64 at a struct offset is safe; worst case wrong number, not crash).
- 34 offset tests (8 original + 24 field-offset assertions + 2 new for start_time/duration). All pass off-device via `ffi.offsetof` without loading any library.

### Phase 2: `audio_device.lua` — real device glue (NEW, device-verified pending)
- **`create_decoder(path)`**: FFmpeg open → find_stream_info → av_find_best_stream → open codec → swr_alloc_set_opts (FLTP→S16) → packet/frame alloc. Returns decoder with `read_frame()` (decode loop mirrors probe section 5: av_read_frame → send_packet → receive_frame → swr_convert), `close()` (idempotent teardown), `get_duration_ms()`, `get_sample_rate()`, `get_channels()`.
- **`create_alsa_sink(opts)`**: Opens `plughw:0,0` (with `hw:0,0`/`default` fallbacks) lazily on first write. S16_LE / RW_INTERLEAVED via `snd_pcm_set_params`. Each `write(data, n)` pushes S16 samples via `snd_pcm_writei`.
- **`create_schedule()`**: Returns `UIManager:scheduleIn` wrapper for output_pump's ~50ms cadence. Falls back to no-op cancel when UIManager unavailable (tests).
- The decode loop and ALSA body mirror `audio_probe.run_play_test` exactly — the ONE confirmed-audible path on PB700K3.

### Phase 2b: `ffmpeg_backend.lua` auto-detect wiring (COMPLETE)
- When `is_available()` is true AND no explicit mocks injected, `new()` auto-builds the real pipeline from `audio_device`.
- **Wrapper-sink pattern**: the decoder factory creates the real ALSA sink (with correct sample_rate/channels from the decoder) as a side effect; a placeholder sink delegates to it. Solves the chicken-and-egg: sink params only known after the decoder opens the file.
- Off-device: auto-detect triggers but `audio_device.create_decoder` returns nil → producer errors gracefully via `getLastError()`. NOT silent clock mode.
- Added `player.getLastError()` delegation to the backend.

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Mirror `audio_probe.run_play_test` exactly (decode loop + ALSA body) | That is the ONE code path confirmed to produce audible playback on PB700K3. Any deviation risks re-introducing dead ends the probe already closed (tts_sm virtual sink, wrong sample_rate offset, FLTP not resampled). Comments in `audio_device.lua` document this constraint at the call sites. |
| Read PTS BEFORE `av_frame_unref` | `av_frame_unref` resets frame fields; reading `frame.pts` after unref returns garbage. The probe reads PTS after swr_convert but before unref — correct order. |
| Per-frame S16 buffer sized `channels * 4096` (vs probe's fixed `int16_t[4096]`) | Same 2x headroom for resample growth, slightly more precise (per-decoder rather than global fixed). No correctness impact since AAC frame_size is 1024 and both buffers are far larger. |
| Store `_channels` on decoder table + capture `decoder_channels` at creation | Initial design used a `local function in_channels_safe(self)` declared after `create_decoder` (relied on LuaJIT file-scoped hoisting). Capturing the constant per-decoder is cleaner and not reliant on hoisting order. |
| Wrapper-sink pattern for auto-detect | The ALSA sink needs sample_rate/channels at construction, but these are only discovered when the decoder opens the file. Rather than coupling sink to decoder or deferring sink creation past the seam boundary, the decoder factory creates the real sink as a side effect and a lightweight wrapper delegates to it. |
| `duration`@72 offset added though UNVERIFIED on-device | The probe warned blind duration derefs caused SIGSEGV — but those were from treating non-pointer values AS POINTERS and dereferencing them. Reading an int64 at offset 72 from a valid AVFormatContext is safe (mapped memory). Worst case: wrong duration number. Device must confirm. |
| Auto-detect off-device surfaces error (not silent clock mode) | A failed decoder should error via `getLastError()`, not pretend to play. Correct semantics: when the real backend is selected but can't decode, that's a real error, not a fallback to a clock that silently advances. |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| `in_channels_safe(self)` referenced in `read_frame` after the helper was deleted | Stale call site not updated when removing the helper function | Captured `decoder_channels = d._channels or 2` at decoder creation; used the captured local in the closure |
| Stale line hashes blocking edits | After multi-edit sessions, the read cache's LINE:HASH anchors drift from the file's current content | Re-read the file to get fresh anchors before each edit (cannot reuse cached anchors across edits) |
| `_channels` never set on decoder table | Decoder returned a table literal without `_channels`; `in_channels_safe` fell back to `2` always | Changed return to build `d_table` explicitly with `_channels = in_channels`, `_sample_rate = in_sample_rate` |
| `frame.pts` read after `av_frame_unref` | Placed PTS capture in the wrong order (after unref) | Moved PTS read BEFORE `av_frame_unref` (unref resets fields) |
| Auto-detect test (slice B) expected CLOCK position advancement off-device | With #39 wiring, auto-detect now triggers real `audio_device` → decoder fails off-device → producer errors, not silent clock | Updated test to verify error surfacing (`getState()=="stopped"`, `getLastError()` is string) |
| Player didn't delegate `getLastError()` | Backend exposes `getLastError()` but player had no passthrough | Added `inst:getLastError()` → `backend.getLastError and backend:getLastError()` |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/audio_ffi.lua` | Expanded to full FFmpeg 6.0 struct layouts (6 structs) + all FFmpeg/ALSA/swresample function sigs + `get_lib()` + `declare_cdefs(ffi)` + `start_time`/`duration` fields (+303/-77 lines) |
| `absaudio/audio_device.lua` | NEW module: `create_decoder` (FFmpeg decode→swr FLTP→S16), `create_alsa_sink` (plughw:0,0 S16_LE), `create_schedule` (UIManager wrapper) — all pcall-guarded, mirrors proven probe |
| `absaudio/ffmpeg_backend.lua` | Auto-detect wiring in `new()`: builds real pipeline from `audio_device` when `is_available()` + no explicit mocks (wrapper-sink pattern) (+41 lines) |
| `absaudio/player.lua` | Added `getLastError()` delegation to backend (+1 line) |
| `spec/test_audio_device.lua` | NEW: 12 tests verifying graceful degradation + API shape (all factories return `(nil, err)` off-device; sink validates required opts; schedule returns usable cancel fn) |
| `spec/test_audio_ffi.lua` | Expanded: +26 offset tests for AVFrame, AVCodecParameters, AVCodecContext, AVFormatContext (+start_time/duration), AVStream, AVRational (8→34 tests) |
| `spec/test_ffmpeg_backend.lua` | Updated auto-detect test to verify error-surfacing (decoder fails off-device) instead of CLOCK position advancement |
| `absaudio/AGENTS.md` | DOX: expanded `audio_ffi` section (structs + get_lib); added `audio_device` section; documented slice D auto-detect |
| `AGENTS.md` | Session log index: added entry for this issue #39 log |

## Test Results

- **680 passed, 0 failed** across 28 test suites (excluding pre-existing `test_api.lua` module-loop error and `test_helper.lua` framework module — both fail identically on clean `develop`).
- New: `test_audio_device.lua` (12 tests), `test_audio_ffi.lua` expanded (34 total).
- Existing pipeline tests unchanged: `test_decode_producer` (11), `test_output_pump` (11), `test_ffmpeg_backend` (45), `test_ffmpeg_backend_pipeline` (12), `test_player` (79).
- `gitnexus_detect_changes`: risk level LOW, 0 affected execution flows (index predates new `audio_device` module).

## Open Items & Next Steps

Device handoff (HITL — PB700K3):
- [ ] Confirm `audio_ffi.is_available()` returns **true** on PB700K3 with expanded cdefs (libaudio-engine + all KEY_SYMBOLS resolve)
- [ ] Confirm `audio_device.create_decoder(path)` opens a downloaded M4B; `read_frame()` returns S16 PCM bytes with advancing PTS
- [ ] Confirm `audio_device.create_alsa_sink()` opens `plughw:0,0`; playback is audible
- [ ] Confirm `ffmpeg_backend` auto-detect plays a short M4B end-to-end (audible, position advances, stop tears down cleanly)
- [ ] Confirm `AVFormatContext.duration`@72 returns correct file duration (offset UNVERIFIED)
- [ ] Confirm wake-lock held during playback, released on stop
- [ ] Update gitnexus index after merge (`node .gitnexus/run.cjs analyze`) so `audio_device` symbols are tracked

---

*Log written by write-log skill*
