# Issue #33 — Audio Slice B: FFmpeg backend contract skeleton (Mac-TDD, FFI mocked)

> **Date:** 2026-06-14
> **Type:** issue
> **Reference:** [GitHub issue #33](https://github.com/AlexKucera/absaudio.koplugin/issues/33) — parent PRD #31 (In-App Audio Playback, FFmpeg + ALSA, Path C); blocked by #32 (slice A, done)

## Goal

Build the FFmpeg backend **module skeleton** implementing the same backend contract
the existing `stub_backend.lua` and `inkview_backend.lua` already implement — but
with the FFI decode/output layer **mocked out** so it is fully unit-testable on the
dev Mac with no device. This is slice B of the audio backend plan.

What is **real and tested** this slice: the transport state machine
(stopped/playing/paused transitions, pause/resume/stop lifecycle, finished
detection), position bookkeeping delegating to slice A's pure math
(`time_math`/`ring_buffer`), and the backend selection hook (`is_available()`).

What is **mocked** this slice: the FFmpeg decode producer, the ALSA output consumer,
and the real FFI cdef shim — all land in later slices (#34+, device).

## What Was Done

- Created `absaudio/ffmpeg_backend.lua` (264 lines) — FFmpeg backend skeleton.
  Implements the **full backend contract** (`play/pause/resume/stop/close`,
  `getPosition/setPosition/getDuration`, `getCurrentTrack/getPlaybackSpeed/
  setPlaybackSpeed`, `isFinished/getState`) **plus** `is_available()`. Plus a
  `getRingBuffer()` test/diagnostic accessor. Mirrors `stub_backend`'s real-time
  wall-clock + `_advanceTime(delta)` time model so transport tests are shared.
- Created `spec/test_ffmpeg_backend.lua` (45 tests) across 15 vertical TDD slices:
  new/getState/getDuration; is_available default probe + mockability; transport
  lifecycle; idempotent transitions; position advance (1x + speed); pause freeze +
  resume; clamp; setPosition seek/clamp/re-baseline; auto-finish + on_finished;
  stop reset; getCurrentTrack; speed get/set; close reset; ring-buffer delegation;
  guarded-FFI stability; player factory selection (explicit ffmpeg + auto-detect).
- Extended `absaudio/player.lua` factory: explicit `opts.backend` of `"stub"`,
  `"inkview"`, or `"ffmpeg"` selects that backend directly; omitted/`"auto"`/
  unknown → auto-detect via `ffmpeg_backend.is_available()`, falling back to stub
  (so emulator/tests are unaffected on the dev machine). Added
  `inst:getBackendName()` for observability (reports which backend was selected).
- Refactor pass removed **27 lines of dead code**: the unused `warn`/`abs_logger`
  require block (never called) and the vestigial `current_track` cache
  (`update_current_track()` maintained it but `getCurrentTrack()` recomputes fresh
  from `effective_position_ms()`, so the cache was write-only state across 6 sites).
- DOX pass: added a "Playback backends" section to `absaudio/AGENTS.md` documenting
  all three backends + the factory contract + slice B status; registered
  `test_ffmpeg_backend.lua` in `spec/AGENTS.md`'s test-file list and corrected the
  test count (→ ~555); corrected stale `busted spec/` test-command docs to the real
  `luajit spec/test_<module>.lua` per-file convention in both `absaudio/AGENTS.md`
  and `spec/AGENTS.md`.
- Updated GitNexus index: 829 → 831 nodes.

Built via strict vertical-slice TDD (one test → RED → minimal impl → GREEN → next),
all 15 slices done in-session by the orchestrator.

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| **Position model: clock-based (wall-clock + `_advanceTime`)**, tracked internally in **milliseconds** | User-approved (ask_user_question). Mirrors `stub_backend`'s proven dual-mode clock so the ffmpeg backend passes the *existing* transport tests unchanged and keeps the skeleton simple. ms is the natural FFmpeg PTS unit (decision log: `position = av_rescale_q(pkt.pts, …, {1,1000})`), so real decode drives position in the same unit in a later slice with no conversion glue. Real-time mode = emulator; `_advanceTime(delta)` switches to a manual virtual clock for deterministic tests. |
| **Position math delegates to `time_math`** (`ms_to_seconds` for `getPosition`, `seconds_to_ms`/`clamp` internally) | Acceptance criterion: "Position math delegates to slice A's pure library." Internal position held in ms; all conversions + the duration clamp go through `time_math.clamp(value, duration_ms)` / `time_math.ms_to_seconds`. |
| **`is_available()`: guarded `pcall(ffi.load("audio-engine"))`, memoized; mockable two ways** | User-approved. Default probe is fully `pcall`-guarded so a missing `.so` or undefined symbol returns `false` and never crashes (acceptance criterion + the `IsPlayingMP3` probe-crash lesson). Mockable via module-level `ffmpeg_backend._set_probe_override(fn)` AND per-instance `opts.ffi_probe` — the latter lets one test instance simulate device while the module stays "dev". Memoized so repeated calls are stable. |
| **Ring buffer instantiated via `ring_buffer.new(capacity)`, decode does NOT feed it yet** | User-approved. Demonstrates delegation to slice A ("ring-buffer behavior delegates to slice A") without fake plumbing. `getRingBuffer()` accessor lets tests assert `fill=0`/`free=capacity`. The decode producer will feed it in slice #34+. |
| **Factory change is additive; always falls back to stub** | Acceptance criterion: "existing player tests still pass (factory change is additive)." Only production caller of the factory is `book_detail.lua:384` (`player.create_from_manifest`); the public delegation API is unchanged → low blast radius. `getBackendName()` added for observability/diagnostics without altering behavior. |
| **Explicit backend names `"stub"`/`"inkview"`/`"ffmpeg"` are never overridden by auto-detect** | A user (or diagnostics) forcing a backend must be respected even on-device. Only omitted/`"auto"`/unknown consults `is_available()`. |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| **`setPosition` crashed: `attempt to call global 'rebase_clock' (a nil value)`** | The `local function rebase_clock()` was declared in the method block *after* `setPosition()` (and `play`/`resume`/`setPlaybackSpeed`) which called it. Lua lexical scoping: the methods captured the name `rebase_clock` from the enclosing scope, but at *call time* no local by that name was visible → resolved to a nil global. | Moved `rebase_clock`'s declaration up into the internal-helpers block (alongside `effective_position_ms`/`check_auto_finish`), before any method that uses it. Lesson: declare helper closures in the helper block, not interleaved with methods. |
| **Issue said "busted tests pass on the dev machine" but `busted` is not installed** | `which busted` → not found. Every existing test runs via the custom `run_test`/`mock.assert_equals` harness with `luajit spec/test_X.lua`. The issue's wording was aspirational; the binding requirement is the project's existing test style. | Matched the existing convention exactly (standalone luajit scripts). Corrected the stale `busted spec/` doc references in `absaudio/AGENTS.md` + `spec/AGENTS.md` to `luajit spec/test_<module>.lua` (DOX: remove contradictory text). |
| **GitNexus `analyze` failed: "database file version 41, current build storage version 40"** | A prior `analyze` (from issue #32's session) wrote a LadybugDB v41 `.lbug` file; the current CLI build expected v40. | Deleted the stale `.gitnexus/lbug` + `.db` artifacts and re-ran `node .gitnexus/run.cjs analyze` → indexed cleanly (831 nodes). |
| **GitNexus function-level impact analysis unavailable for this Lua project** | GitNexus's Lua parser only indexed File/Folder nodes (no `Function` symbols), so `impact({target:"player.create"})` → "not found" and `MATCH (n:Function)` → empty. | Did the manual equivalent: `grep` mapped callers of the factory (only `book_detail.lua:384`) and confirmed the public API is unchanged → verified low blast radius independently. `detect_changes` confirmed `risk_level: low, affected_count: 0`. |
| **Vestigial `current_track` cache was write-only dead state** | `update_current_track()` wrote `current_track` from `position_ms`, but `getCurrentTrack()` recomputed fresh from `effective_position_ms()` (the correct source — the cached value would be stale during playback). The cache was written in 5 places and read in none. | Removed `current_track`, `update_current_track()`, and all 6 write sites in the refactor pass (part of −27 lines dead code). `getCurrentTrack()` now computes from the live effective position. |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/ffmpeg_backend.lua` (new, 264 lines) | FFmpeg backend skeleton: full contract + `is_available()` + `getRingBuffer()`; ms-based position via `time_math`; owns a `ring_buffer`; guarded memoized FFI probe; mockable via `_set_probe_override`/`opts.ffi_probe` |
| `spec/test_ffmpeg_backend.lua` (new, 45 tests) | 15 vertical TDD slices: contract, transport, position, seek, finish, speed, ring buffer, guarded FFI, factory selection |
| `absaudio/player.lua` | Factory: explicit backend selection + auto-detect (`is_available()` → stub fallback); added `inst:getBackendName()`; lazy `ffmpeg_backend` loader |
| `absaudio/AGENTS.md` | New "Playback backends" section (all 3 backends + factory contract + slice B status); corrected `busted`→`luajit` verification command |
| `spec/AGENTS.md` | Added `test_ffmpeg_backend.lua` to test list; test count → ~555; corrected `busted`→`luajit` verification command |

## Verification

```
luajit spec/test_ffmpeg_backend.lua → 45 passed, 0 failed
luajit spec/test_player.lua         → 79 passed, 0 failed   (unchanged — additive)
Full suite (all audio suites):      → 555 passed, 0 failed  (baseline 510 → +45)
```

GitNexus `detect_changes`: `risk_level: low`, `affected_count: 0`. Reindexed: 831 nodes.

All 7 acceptance criteria PASS (full contract; same transport tests as stub/inkview
with FFI mocked; position math + ring buffer delegate to slice A; `is_available()`
mockable + used by factory, dev→stub; guarded FFI never crashes; tests pass on Mac
no device; existing player tests unchanged). See the session's acceptance report.

No device testing possible this slice — the FFI decode layer is mocked by design.
`is_available()` returns `false` on the dev Mac, so the factory stays on stub and
emulator behavior is intentionally unchanged.

## Open Items & Next Steps

- [ ] **Commit** this work (TDD skill rules: orchestrator did not commit; user triggers it).
- [ ] **Slice C / FFI cdef shim** (device, issue #34): declare the FFmpeg/ALSA cdefs
  (guarded), implement the real `is_available()` key-symbol validation against the
  v4 export list. Deploy, confirm the shim loads without crashing on the PB700K3.
- [ ] **Decode producer** (device): wire FFmpeg `avformat_open_input` → `av_read_frame`
  → `avcodec_send_packet`/`receive_frame` → `swr_*` resample to S16LE/48k/stereo;
  write PCM into the ring buffer; compute `position = av_rescale_q(pkt.pts, …, {1,1000})`.
- [ ] **Output consumer** (device): `scheduleIn(0.05)` pump draining the ring to ALSA
  via `push_output_buffer` (route through `tts_sm`). The `ring_buffer` module slots in here.
- [ ] **Transport + seek + speed** (device): wire `play/pause/resume/stop` to real
  decode/output; seek = reopen-at-offset; speed via the `atempo.chain()` graph
  (slice A). Integrate position polling into `book_detail.lua`.
- [ ] **ABS sync integration** (device + server): push live position to ABS on the
  existing sync cadence; resume from server position.

---

*Log written by write-log skill*
