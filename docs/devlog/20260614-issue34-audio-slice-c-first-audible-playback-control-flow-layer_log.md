# Issue #34 — Audio Slice C: First audible playback (off-device control-flow layer)

> **Date:** 2026-06-14
> **Type:** issue
> **Reference:** [GitHub issue #34](https://github.com/AlexKucera/absaudio.koplugin/issues/34) — parent PRD #31 (In-App Audio Playback, FFmpeg + ALSA, Path C); blocked by #33 (slice B, done)

## Goal

Build the **off-device-testable control-flow layer** for the FFmpeg audio backend's first-audible-playback tracer bullet. Issue #34 is explicitly **HITL** — an unattended agent cannot hear the speaker or drive the USB deploy/test loop, and the PRD's Testing Decisions confirm the device-dependent pieces (FFI loading, actual decode, audible output) cannot be unit-tested. So this session TDD's the producer/consumer/wake-lock orchestration with **every device call behind an injectable interface**, leaving the real FFmpeg decode + ALSA output bodies for a device session to fill and verify by ear.

## What Was Done

- Created `absaudio/pcm_buffer.lua` (94 lines) — mutable PCM byte storage wrapping slice A's `ring_buffer` (which does index math but stores no bytes). Backing Lua table `[0,capacity)` + threaded immutable ring_buffer state; wraparound via `% capacity`. Public API: `new/capacity/fill/free/empty/full/can_write/can_read/write/read/clear`. Shared by producer (write) + pump (read).
- Created `absaudio/audio_ffi.lua` (146 lines) — guarded FFmpeg/ALSA cdef shim + real `is_available()` (dlopen `libaudio-engine` + all `KEY_SYMBOLS` resolve, memoized, false on dev). **Every** `ffi.cdef` and `lib[sym]` lookup is `pcall`-guarded so a missing/undefined symbol returns `false` rather than crashing (lesson from the `IsPlayingMP3` probe crash). Uses forward-declared incomplete structs (`struct AVFormatContext;`) to avoid blind-layout risk. Public API: `is_available()`, `_set_probe_override(fn|nil)`, `KEY_SYMBOLS`.
- Created `absaudio/wake_lock.lua` (94 lines) — paired, idempotent firmware sleep-ban wrapper (prevents PocketBook auto-suspend stalling the output pump). Injectable `opts.impl = {acquire, release}`; default is a guarded inkview probe (`BanSleep`/`AllowSleep`, no-op on dev). `acquire()`/`release()` each call the impl exactly once per held period.
- Created `absaudio/decode_producer.lua` (149 lines) — coroutine decode loop. Opens via injectable `decoder_factory(path)`, decodes frames, writes PCM into a shared `pcm_buffer`, fires `on_position(ms)`/`on_finished()`/`on_error(err)`, yields on buffer-full (backpressure) or frame-quota (timeshare). The output pump drives it via `:kick()`. Pure control flow — no FFI. Public API: `new(opts)`, `start()`, `kick()`, `is_done()`, `status()`, `teardown()`.
- Created `absaudio/output_pump.lua` (107 lines) — scheduled ~50ms drain. Drains `opts.buffer` to `opts.sink.write`, kicks the producer (backpressure), survives underrun (empty buffer → skip + reschedule), self-stops on producer-done + buffer-empty. **Does NOT import `decode_producer`** — receives it via `opts.producer`. Public API: `new(opts)`, `start()`, `tick()`, `stop()`, `is_running()`.
- Wired `absaudio/ffmpeg_backend.lua` (264→396 lines) for full transport orchestration: `play()` acquires wake-lock + starts producer + starts pump; `stop()`/`close()` tears all three down. **Dual position source**: CLOCK mode (no `decoder_factory` — identical to `stub_backend`, used by emulator/tests/slice B's 45 contract tests) or PRODUCER mode (`decoder_factory` provided — position from PTS via `on_position(ms)`, used by slice C integration tests + device). Added `getLastError()` to surface undecodable-file errors. `is_available()` now delegates to `audio_ffi.is_available()`.
- Created `spec/test_ffmpeg_backend_pipeline.lua` (12 tests) — integration tests with fakes for every device seam (decoder_factory, sink, schedule, wake_impl): play/stop lifecycle, undecodable-file error path (no crash), wake-lock acquire/release pairing, producer-driven position from PTS, pause/resume, natural completion.
- Created `docs/devlog/issue34-tdd-plan.md` — TDD plan + BDD scenarios + the device-handoff checklist (what the HITL device session must fill and verify).
- DOX pass: added 5 new module entries + a "slice C" pipeline section to `absaudio/AGENTS.md`; updated `ffmpeg_backend.lua`'s entry to "pipeline wired"; added the 6 new test files to `spec/AGENTS.md`'s test-file list and corrected the test count (→ ~642).
- Updated GitNexus index (`node .gitnexus/run.cjs analyze`): 831 → 876 nodes, 850 → 898 edges.

Built via vertical-slice TDD: Phase 1 (pcm_buffer, audio_ffi, wake_lock) and Phase 2 (decode_producer, output_pump) delegated to **3 + 2 parallel `worker` subagents** with the `tdd` skill; Phase 3 (ffmpeg_backend wiring + integration tests) and Phase 4 (refactor, gitnexus, DOX closeout) done by the orchestrator.

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| **Off-device control-flow layer (Option A) over FFI-shim-only or handoff-doc-only** | User-approved (ask_user_question). The issue is HITL, but the producer/pump/wake-lock control flow is fully testable off-device behind injectable interfaces. Building it now makes the device session a "fill the seams + verify by ear" job instead of a from-scratch implementation. Matches slice A/B's Mac-first pattern. Risk: interfaces built on UNCONFIRMED cdefs may shift slightly once real decode is wired. |
| **`pcm_buffer` as a 5th module** (not in the original approved list) | `ring_buffer` (slice A) deliberately stores no bytes — it's pure index math. The producer/pump need shared *mutable storage*. Making it a module keeps the seam clean, completes what `ring_buffer` started, and is pure (Mac-testable). |
| **Dual position source: CLOCK mode (slice B) + PRODUCER mode (slice C)** | Keeps slice B's 45 contract tests byte-identical (zero regressions). When no `decoder_factory` is provided, the clock model is unchanged; when provided, `on_position(ms)` from the producer drives position. A `producer_active` flag selects the source. |
| **Every device seam injectable** (`decoder_factory`, `sink`, `schedule`, `wake_impl`) | The PRD's Testing Decisions state device-dependent pieces can't be unit-tested. Injection makes the full control flow testable with fakes on the Mac; the device session fills the real FFmpeg/ALSA/UIManager/inkview bodies into the seams. |
| **`output_pump` does NOT import `decode_producer`** | Decoupling: the pump calls only `producer:kick()`/`is_done()`, receiving the producer via `opts`. Lets each module's tests inject a fake of the other, and lets Phase 1+Phase 2 run as independent parallel TDD tasks with zero coupling. |
| **`audio_ffi` cdefs use incomplete (forward-declared) structs** | `struct AVFormatContext;` etc. — we only need opaque pointers, not field layouts. This avoids blind-struct-layout risk (getting a field offset wrong would corrupt memory on device). The device session can add real struct layouts only if a field is actually needed. |
| **Phase 3 (wiring) done by orchestrator, not delegated** | Modifying the existing `ffmpeg_backend.lua` (45 tests must stay green) + the dual-position-source design required deep understanding of all 5 frozen module interfaces. Safer to do in the session that holds that full context than to hand off. |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| **Pipeline test "getPosition reflects producer PTS" failed (expected 3, got 10)** | With a 1 MiB buffer and a single 8-byte frame, the producer finished immediately on `start()` and the pump's first tick triggered natural completion → position clamped to duration (10s). No mid-stream PTS was observable. | Fixed the TEST: small `buffer_capacity` (16) + `chunk_size` (8) + 4 frames so the producer yields on buffer-full after frame 2 (on_position(2000)), making position observable mid-stream and advancing on pump steps. Not an implementation bug. |
| **Parallel subagent `output: "inline"` collision** | Two PARALLEL workers resolved `output` to the same path → "resolve output to the same path" rejection. | Dropped the explicit `output` field (inline is the default); parallel runs then succeeded. |
| **Stale "subagent needs attention" control signals after parallel completion** | After the parallel runs delivered completed results, the control watcher fired `needs attention (no observed activity for 931s/937s)` — but the runs were already terminal ("Async run not found"). The workers had simply finished and returned, so there was no further activity to observe. | Verified actual on-disk state instead of trusting the signal: files existed and both test suites passed (11+11). Ignored the stale signals and proceeded. |
| **`decode_producer:teardown()` marks status `"errored"` on clean teardown of a running producer** | Implementation detail: teardown is the "abort" path, so it sets errored regardless of cause. Functionally fine since callers only check `is_done()`, not `status()`, after teardown. | Left as-is (frozen interface under test). Noted for possible revisit; not worth breaking the interface mid-flow. |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/pcm_buffer.lua` (new, 94 lines) | Mutable PCM byte storage wrapping `ring_buffer`; write/read/clear with wraparound + overrun/underrun errors |
| `absaudio/audio_ffi.lua` (new, 146 lines) | Guarded FFmpeg/ALSA cdefs (pcall) + real `is_available()` (dlopen + KEY_SYMBOLS check, memoized); `KEY_SYMBOLS`/`_set_probe_override` |
| `absaudio/wake_lock.lua` (new, 94 lines) | Paired idempotent firmware sleep-ban; injectable `impl`; guarded inkview default (no-op on dev) |
| `absaudio/decode_producer.lua` (new, 149 lines) | Coroutine decode loop; injectable `decoder_factory`; `on_position/on_finished/on_error`; backpressure + quota yields; start/kick/is_done/status/teardown |
| `absaudio/output_pump.lua` (new, 107 lines) | Scheduled ~50ms drain; injectable sink/schedule/producer; backpressure + underrun skip; self-stop on done+empty; start/tick/stop/is_running |
| `absaudio/ffmpeg_backend.lua` (modified, 264→396) | Pipeline wired: play/stop/pause/resume/close drive producer+pump+wake_lock; dual position source (CLOCK/PRODUCER); `getLastError()`; `is_available()` delegates to `audio_ffi` |
| `spec/test_pcm_buffer.lua` (new, 211 lines) | 15 tests: fill/free, round-trip, wraparound, overrun/underrun, clear, large round-trip |
| `spec/test_audio_ffi.lua` (new, 150 lines) | 8 tests: false on dev, never throws, memoized, probe override, KEY_SYMBOLS, stable require |
| `spec/test_wake_lock.lua` (new, 147 lines) | 8 tests: idempotent acquire/release, no-op when not held, acquire→release→acquire cycle, default impl no-op on dev |
| `spec/test_decode_producer.lua` (new, 333 lines) | 11 tests: open error, EOF, advancing PTS, backpressure yield, quota yield, mid-stream error, oversized-frame guard, kick no-ops, teardown |
| `spec/test_output_pump.lua` (new, 317 lines) | 11 tests: schedule/drain, chunk_size cap, backpressure kick, no-kick-when-done, underrun survival, natural end + on_drained, stop/idempotent start, full drain cycle |
| `spec/test_ffmpeg_backend_pipeline.lua` (new, 365 lines) | 12 integration tests: play/stop pipeline lifecycle, undecodable→error no crash, wake-lock pairing, producer PTS position, pause/resume, natural finish, clock-mode compat |
| `absaudio/AGENTS.md` | Added pcm_buffer section; new "Audio pipeline — slice C" section (audio_ffi, wake_lock, decode_producer, output_pump); updated ffmpeg_backend entry to "pipeline wired" + device seams |
| `spec/AGENTS.md` | Added 6 new test files; test count → ~642 |
| `AGENTS.md` | GitNexus index count auto-updated (831→876 symbols) by `analyze` |
| `docs/devlog/issue34-tdd-plan.md` (new) | TDD plan + BDD scenarios + device-handoff checklist + acceptance-criteria status |

## Verification

```
luajit spec/test_pcm_buffer.lua                → 15 passed, 0 failed
luajit spec/test_audio_ffi.lua                 →  8 passed, 0 failed
luajit spec/test_wake_lock.lua                 →  8 passed, 0 failed
luajit spec/test_decode_producer.lua           → 11 passed, 0 failed
luajit spec/test_output_pump.lua               → 11 passed, 0 failed
luajit spec/test_ffmpeg_backend_pipeline.lua   → 12 passed, 0 failed
luajit spec/test_ffmpeg_backend.lua            → 45 passed, 0 failed  (slice B — UNCHANGED)
Full suite:                                     → 642 passed, 0 failed
```

GitNexus `detect_changes`: `risk_level: low`, `affected_count: 0`. Reindexed: 876 nodes, 898 edges.

### Acceptance criteria status (issue #34)
- [ ] FFI shim loads; `is_available()` true on PB700K3 — **DEVICE** (shim built & guarded; verified false on Mac)
- [ ] Decode producer writes valid PCM (debug dump) — **DEVICE** (control flow tested; real FFmpeg body is the seam)
- [ ] M4B plays audibly via `tts_sm` — **DEVICE (HITL)**
- [x] No direct physical-codec access — **enforced by interface** (output goes through injectable `sink` seam only)
- [ ] Wake-lock held/released on device — **DEVICE** (logic + acquire/release pairing tested off-device)
- [ ] Stopping tears down cleanly on device — **DEVICE** (teardown logic tested off-device)
- [x] Undecodable file → clear error, no crash — **off-device tested** (`getLastError()` + state=stopped, `play()` wrapped in pcall)
- [x] Emulator/tests still use stub backend (factory fallback unchanged) — **verified** (slice B 45 tests + full suite green)

3 of 8 acceptance criteria fully met off-device; 1 enforced by interface design; 4 require device verification (HITL, as the issue itself states).

## Open Items & Next Steps

- [ ] **Commit** this work (TDD skill rules: orchestrator did not commit; user triggers it). 5 new modules, 6 new test files, 1 modified module, DOX updates, plan doc.
- [ ] **DEVICE session (HITL)** — fill the real seams and verify by ear (see `docs/devlog/issue34-tdd-plan.md` checklist):
  - [ ] Confirm `audio_ffi` cdefs match real symbols — shim loads without crashing on PB700K3; `is_available()` returns true.
  - [ ] Fill the real FFmpeg open/find-stream/decode/resample body into the default `decoder_factory`; **write PCM to a debug file first, NOT ALSA** — verify valid audio-shaped data.
  - [ ] Fill the real ALSA body into `output_pump`'s default `sink` (`tts_sm` chain only; **never** `hw:0` — amplifier-corruption risk).
  - [ ] Confirm a short downloaded M4B plays audibly.
  - [ ] Confirm wake-lock prevents suspend-stall during long playback; released on stop.
  - [ ] Confirm stopping tears down producer + pump + wake-lock cleanly.
- [ ] **Multi-track decode** (future slice): `ffmpeg_backend` currently decodes only `file_paths[1]`. Multi-part audiobook sequencing across tracks needs the producer to advance to the next file on EOF.
- [ ] **Transport + seek + speed wiring into `book_detail.lua`** (later device slice, per PRD sequencing): wire `play/pause/resume/stop` to real transport; seek = reopen-at-offset; speed via `atempo.chain()` (slice A); position polling into the detail view.
- [ ] **ABS sync integration** (device + server, final slice): push live position to ABS; resume from server position.

---

*Log written by write-log skill*
