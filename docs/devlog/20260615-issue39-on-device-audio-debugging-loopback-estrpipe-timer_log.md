# Issue #39 / Slice D — On-Device Audio Debugging: Loopback Routing, ESTRPIPE Recovery, Position & Timer

> **Date:** 2026-06-15
> **Type:** issue
> **Reference:** Issue #39 (Audio Slice D: Port confirmed FFmpeg/ALSA glue into production pipeline)

## Goal

Get real FFmpeg-decoded, ALSA-output audio to actually play **audibly and continuously** through the in-app book-detail UI on a PocketBook PB700K3. The FFmpeg/ALSA glue layer (from the prior session) compiled and passed all off-device tests, and a backend-readiness probe confirmed decode worked — but pressing Play produced silence, a stuck timer, and audio that died at ~29 seconds. This session was the on-device debugging gauntlet to close those gaps.

## What Was Done

- **Discovered PocketBook's `alsaloop` audio-routing architecture** and retargeted the ALSA output device accordingly. PocketBook runs `alsaloop -Chw:Loopback,1,0 -P hp -t500000 --sync=none -U -v` at boot; it exclusively grabs the hardware device (`hw:0,0`) and bridges the ALSA Loopback card to the speaker. User apps must write to the **Loopback playback device 0** (`plughw:1,0`), not the hardware device. Changed `ALSA_DEVICES` in `audio_device.lua` to prioritize `plughw:1,0` (with hardware fallbacks for when alsaloop is absent).
- **Fixed ESTRPIPE (-86) suspend recovery** that killed audio at ~29s. The Loopback device suspends the PCM stream after ~29s of playback; `snd_pcm_writei` returns `-86`. The recovery code checked for `-77` (wrong errno value), so the error fell through to "FATAL-giveup". Corrected to `-86`, added `snd_pcm_resume()` (clean resume) with `snd_pcm_prepare()` fallback, up to 3 retry attempts.
- **Added FFI bindings** for `snd_pcm_resume` and `snd_strerror` in `audio_ffi.lua`.
- **Fixed ALSA PCM handle leak** in `ffmpeg_backend.lua`: `stop_pipeline()` stopped the pump and tore down the producer but never called `sink.close()`, so `snd_pcm_close()` never ran. Every play→stop leaked one PCM handle; subsequent opens hit `-16` (EBUSY). Added `pcall(sink.close)` to `stop_pipeline()`.
- **Fixed position tracking (timer stuck at zero)** in `ffmpeg_backend.lua`: `effective_position_ms()` returned `producer_position_ms` when `producer_active`, but the producer decodes ~12s **ahead** into a 1 MiB ring buffer — so the displayed position was the decode-ahead position, not the playback position. Made position **always clock-based** (`position_ms + elapsed × speed`). `play()` now calls `rebase_clock()` even in producer mode; `pause()` always snapshots `position_ms`; `resume()` always rebases the clock.
- **Fixed timer display not animating** in `book_detail.lua`: `_scheduleNextPlaybackUpdate()` scheduled a 1.0s recurring callback that, in the "still playing" branch, rescheduled itself but **never called `_updatePlaybackDisplay()`**. The timer stayed frozen during playback, then jumped to the correct value on pause. Added the `_updatePlaybackDisplay()` call + a guard for the view being closed mid-tick.
- **Added pcall-guarded `logger`** to `audio_device.lua` (was using bare `logger`, a KOReader global unavailable off-device → 6 test crashes). Falls back to `print` in tests.
- **Added sample-count position fallback** in `audio_device.lua` `read_frame()`: accumulates `_samples_decoded` and computes `pts_ms = floor(samples * 1000 / sample_rate)` when `frame.pts` reads as 0 (AVFrame field-offset mismatch masks pts).
- **Stripped all `[DEBUG-a39]` instrumentation** added during diagnosis (verbose open-failure dumps, `/proc/asound` and `/proc/*/fd` PID-holder scans, `snd_strerror` decoding, write-count logging, pipeline-end logging). Replaced with production-quality `logger.info`/`logger.warn` calls.
- **Built the on-device diagnostic methodology** that found the culprit: progressively narrowing the failure — `snd_strerror` confirmed `-16`=EBUSY; `/proc/asound/card0/pcm0p/sub0/status` revealed an `owner_pid` holding the device `OPEN` with `no setup`; reading that PID's `/proc/PID/cmdline` identified `alsaloop`.
- **5 new regression tests** (692 total pass): clock-based position during producer playback; pause snapshots/resume continues; stop closes the sink (leak); close closes the sink; pause does NOT close the sink.

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Write to Loopback device (`plughw:1,0`) instead of hardware (`hw:0,0`) | PocketBook's `alsaloop` daemon exclusively owns the hardware DAC at boot (`-Chw:Loopback,1,0 -P hp`). Direct `hw:0,0`/`plughw:0,0` opens return `-16` (EBUSY). The Loopback card cross-connects device pairs: writing to device 0 playback feeds device 1 capture, which is exactly where alsaloop reads. This is the same routing the native audiobook player uses. Prior session's audible play-test worked only because alsaloop wasn't running during that probe window. |
| Clock-based position, not producer PTS, for progress display | The decode producer runs ahead of playback, filling a 1 MiB ring buffer (~12s of audio at 22050 Hz stereo). `producer_position_ms` reflects where the **decoder** is, not where **playback** is. The wall clock (`position_ms + elapsed × speed`) is accurate for forward playback and handles pause/resume via snapshots. Producer PTS is fundamentally unsuitable for progress display in a buffered pipeline. |
| `snd_pcm_resume()` before `snd_pcm_prepare()` for ESTRPIPE | `snd_pcm_resume` cleanly resumes a suspended stream without dropping/re-preparing buffers. Some drivers return `-ENOSYS` (resume not supported); fall back to `prepare()` then. `prepare()` resets the stream to `PREPARED` state, which works but is heavier. |
| Close sink on `stop()` but NOT on `pause()` | `stop()` is a full teardown (leaving the view, finishing) — the device must be released. `pause()` only stops the output pump so the producer yields on buffer-full; the ALSA handle must stay open across pause/resume to avoid re-open latency and EBUSY churn. |
| pcall-guard `logger` in `audio_device.lua` | KOReader's `logger` is a global not available off-device. Tests crashed with `attempt to index global 'logger' (a nil value)`. pcall-guard with print fallback matches the `abs_logger` pattern (issue #24). |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| No audio — `snd_pcm_open` returns -16 (EBUSY) on every device | PocketBook's `alsaloop` daemon (PID ~1167) exclusively holds `hw:0,0` at boot. `plughw:0,0`, `hw:0,0`, `dmix`, and `default` all fail. Even a full power cycle doesn't help — alsaloop restarts and re-grabs the device. | Write to `plughw:1,0` (Loopback card 1, device 0). alsaloop bridges Loopback→speaker. |
| Audio dies at ~29s; `writei ret=-86` then silence | ESTRPIPE (errno **86**, stream suspended) was checked as **-77** (wrong value). The Loopback device suspends after ~29s. Wrong errno → fell through to FATAL-giveup → permanent silence. | Corrected errno check to `-86`; added `snd_pcm_resume()` + `prepare()` fallback + retry. |
| Timer frozen at 0 during playback; jumps to correct value on pause | `effective_position_ms()` returned decode-ahead `producer_position_ms` (producer decodes ~12s into buffer). AND `play()` never called `rebase_clock()` in producer mode, breaking the clock fallback. | Position always clock-based; `play()` rebases even in producer mode. |
| Timer animates on pause but not during playback | `_scheduleNextPlaybackUpdate()` recurring branch rescheduled itself without calling `_updatePlaybackDisplay()`. | Added `_updatePlaybackDisplay()` call before reschedule + view-closed guard. |
| No audio after first play→stop→play cycle | `stop_pipeline()` never called `sink.close()` → leaked one PCM handle per stop → next open = EBUSY. | Added `pcall(sink.close)` to `stop_pipeline()`. |
| Stale debug log kept reappearing; "fixes" seemed not to deploy | User copied the debug file to Mac, but the device had a **newer** version. Plugin Lua files hot-reload on navigation, but C-level FDs belong to the process — full restart needed to release leaked handles. During one round, the deployed code genuinely wasn't the latest. | Always read debug directly from `/Volumes/PB700K3/absaudio_write_debug.txt` (the live device file), not a user-copied stale version. Verify deployed code via `grep` against the device path. |
| Diagnostic `/proc/*/fd` scan found NO holder; wasted a round | `readlink` via `ffi.C.readlink` likely failed/crashed silently on PocketBook LuaJIT; the HOLDER scan produced no output. | Read `owner_pid` directly from `/proc/asound/card0/pcm0p/sub0/status`, then read that PID's `/proc/PID/cmdline` — more reliable than symlink scanning. |
| ALSA -16 persists even after "restart" | Exiting to PocketBook home + relaunching KOReader is NOT a process restart. KOReader keeps running while USB-connected. And the alsaloop lock is at the **kernel** level — even a real process exit doesn't release it; only a full device power cycle resets the sunxi audio driver. | Full power cycle (hold power until off, wait, power on). The leak fix prevents recurrence. |
| `mock.assert_true`/`assert_false` don't exist in test framework | Test framework only has `mock.assert_equals`. | Use `mock.assert_equals(true, val, msg)` / `mock.assert_equals(false, val, msg)`. |
| `audio_device.lua` write tests crashed: `logger` is nil | Introduced bare `logger.warn`/`logger.info` calls; `logger` is a KOReader global unavailable off-device. | pcall-guarded `require("logger")` with print fallback at module top. |
| `scheduleIn(0)` starves the event loop | (prior session, but reinforced here during pump debugging) `handleInput()` drains all due tasks in a loop; `scheduleIn(0)` = immediately due = starves input. | Use `scheduleIn(0.05)` for pump ticks. |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/audio_device.lua` | `ALSA_DEVICES` reprioritized to `plughw:1,0` (Loopback) with alsaloop docs; ESTRPIPE (-86) recovery via `snd_pcm_resume`+`prepare` fallback (was wrong -77); `logger` pcall-guard; sample-count `pts_ms` fallback in `read_frame()`; stripped all `[DEBUG-a39]` instrumentation |
| `absaudio/audio_ffi.lua` | Added `snd_pcm_resume` + `snd_strerror` FFI bindings (function list + cdecl) |
| `absaudio/ffmpeg_backend.lua` | `effective_position_ms()` always clock-based; `play()` rebases clock in producer mode; `pause()` always snapshots; `resume()` always rebases; `stop_pipeline()` calls `sink.close()` (leak fix); stripped pipeline-end debug logging |
| `absaudio/book_detail.lua` | `_scheduleNextPlaybackUpdate()` recurring branch now calls `_updatePlaybackDisplay()` + view-closed guard |
| `spec/test_ffmpeg_backend_pipeline.lua` | 5 new tests: clock-based position, pause/resume snapshot, sink-close-on-stop (×2), pause-keeps-sink-open; fake_sink gained `close`/`is_closed` |
| `spec/test_audio_device.lua` | (prior in session) sample-count position regression tests |

## Open Items & Next Steps

- [ ] **AVFrame.pts field-offset mismatch**: `ffi.offsetof(AVFrame, pts)` = 160 but declared struct has it at 192. Currently masked by clock-based position + sample-count fallback. Correct the struct layout for accurate chapter-boundary seeking.
- [ ] **Background playback control**: Audio continues after leaving the book-detail view (`onClose` doesn't stop the player). Need either a "Stop playback" main-menu item or wire `player:stop()`/`close()` into `BookDetailView:onClose()`.
- [ ] **The sink-close-on-stop fix needs on-device verification** of the play→stop→play→stop leak cycle (only continuous single-playback was confirmed this session).
- [ ] **Commit** all changes once on-device playback is re-confirmed with the stripped instrumentation (clean code deployed; awaiting final confirmation).
- [ ] **Update `absaudio/AGENTS.md`** Slice D section with the alsaloop/Loopback routing learning (it currently documents `plughw:0,0`).

---

*Log written by write-log skill*
