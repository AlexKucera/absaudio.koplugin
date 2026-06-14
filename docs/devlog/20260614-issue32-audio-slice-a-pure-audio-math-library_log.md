# Issue #32 — Audio Slice A: Audio math library (pure, Mac-TDD)

> **Date:** 2026-06-14
> **Type:** issue
> **Reference:** [GitHub issue #32](https://github.com/AlexKucera/absaudio.koplugin/issues/32) — parent PRD #31 (In-App Audio Playback, FFmpeg + ALSA, Path C)

## Goal

Build the pure-Lua math foundation for the FFmpeg audio backend (PRD #31) — three
zero-dependency modules (no FFI, no KOReader globals, no I/O) that are fully
unit-testable on the dev Mac with the project's existing custom harness. This is
slice A (the first of the audio slices): every later slice (backend contract
conformance, FFI shim, decode producer, output consumer, transport, sync) depends
on these three pure concerns.

Three responsibilities, all pure functions:
1. **Time-base → seconds/milliseconds conversion** (FFmpeg `av_rescale_q` arithmetic)
2. **Ring-buffer index math** (fill/free/overrun/underrun/wraparound, no PCM storage)
3. **`atempo` filter-chain string builder** (single-stage 0.5–2.0 + chaining for out-of-range)

## What Was Done

- Created `absaudio/time_math.lua` (106 lines) — FFmpeg `av_rescale_q` arithmetic.
  Public API: `rescale(value, from_tb, to_tb)`, `to_ms(pts, time_base)`,
  `to_seconds(pts, time_base)`, `ms_to_seconds(ms)`, `seconds_to_ms(sec)`,
  `clamp(value, max)`. Rounding = half-away-from-zero (`AV_ROUND_NEAR_INF`).
- Created `absaudio/ring_buffer.lua` (158 lines) — immutable ring-buffer index math.
  State `{capacity, write, read}` where `write`/`read` are absolute monotonic byte
  counters (only grow). Public API: `new(capacity)`, `fill`, `free`, `empty`,
  `full`, `can_write(n)`, `can_read(n)`, `write(n)`, `read(n)` (return NEW state,
  error on overrun/underrun), `write_slot`, `read_slot` (wraparound via `% capacity`).
- Created `absaudio/atempo.lua` (63 lines) — `atempo` filter-chain builder.
  Public API: `chain(speed)` → string (e.g. `"atempo=1.5"`, `"atempo=2,atempo=2"`).
  Constants `STAGE_MIN = 0.5`, `STAGE_MAX = 2.0`. Errors if speed ≤ 0 or non-number.
- Created `spec/test_time_math.lua` (18 tests), `spec/test_ring_buffer.lua` (15 tests),
  `spec/test_atempo.lua` (20 tests) — **53 new tests, all passing**.
- All three modules follow the `chapter_navigator.lua` pure-module style exactly:
  header doc-comment block (purpose, "Pure logic (no FFI, no KOReader dependencies,
  no I/O).", data-shape/conventions, Public API list), `local M = {}`, functions, `return M`.
- DOX pass: generalized `absaudio/AGENTS.md`'s pure-logic section into four subsections
  (chapter_navigator + the 3 new modules); added the 3 test files to `spec/AGENTS.md`'s
  test-file list.
- Updated GitNexus index (`npx gitnexus analyze`): 758 → 817 nodes, 773 → 834 edges.

Built via strict vertical-slice TDD (one test → RED → minimal impl → GREEN → next),
delegated to **3 parallel `worker` subagents** (one per module — independent files,
no conflicts), each with the `tdd` skill injected.

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| **Three focused modules** (time_math / ring_buffer / atempo) instead of one combined `audio_math.lua` | User-approved choice. The PRD #31 calls it singularly "a pure position-math layer", but the three concerns are independent (no shared state/helpers). One-module-per-file matches the project convention (`chapter_navigator`, `config`). Separate files also enable clean parallel TDD on independent files. Each is a deeper single-responsibility module. |
| **Custom `run_test`/`mock.assert_equals` harness via `luajit`, NOT `busted`** | The issue said "busted tests pass on the dev machine", but `which busted` returns nothing — busted is not installed. Every existing test (`test_chapter_navigator`, `test_config`, etc.) uses the custom `run_test` harness with `luajit spec/test_X.lua`. The acceptance criterion "follows the project's existing pure-module test style" is the binding requirement; matched it exactly rather than introducing a new test framework. |
| **Ring buffer: absolute monotonic counters, immutable state** | Instead of wraparound counters that reset at capacity (classic ring-buffer bug surface), `write`/`read` only grow. `fill = write - read` is then exact and trivial; overrun/underrun = simple comparisons; wraparound is deferred to index-time (`counter % capacity`). Immutability (`write`/`read` return NEW state tables) makes the decode/output pump's threading of state through a coroutine + scheduled pump safe and testable. Lua doubles handle long-book byte counts well within 2^52 (~4.5 PB). |
| **`atempo.chain()` chaining algorithm: divide by STAGE_MAX until in range** | Iteratively consume 2.0 stages going up (or 0.5 stages going down) until the remainder lands in [0.5, 2.0], then emit a final stage for the remainder. Product of all stages always equals input speed. `%g` formatting (1.0→"1", 1.5→"1.5") mirrors `player.format_speed` and matches FFmpeg's own filter-string output. |
| **`rescale()` round-half-away-from-zero (`AV_ROUND_NEAR_INF`)** | This is exactly FFmpeg's `av_rescale_q` default rounding, so the module's output matches what the real FFmpeg decode loop will compute on-device. Test pins both positive (0.5→1) and negative (-0.5→-1) rounding. |
| **3 parallel worker subagents** | The three modules are independent files with zero shared code, so parallel TDD is conflict-free. Kept the orchestrator context clean and cut wall-clock time. |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| **NTSC fractional timebase test value was wrong** | The task spec pinned `to_ms(24024, {num=1001, den=24000}) == 1001`, but 24024 ticks × (1001/24000 s) ≈ 1002 s = 1,002,001 ms (off by ×1001). The `rescale` implementation was correct (faithful `av_rescale_q`); the expected value in the spec was wrong. | The time_math worker caught it, proved the math, and corrected the test to `to_ms(24, {num=1001, den=24000}) == 1001` (24 ticks × 1001/24000 = 1.001 s = 1001 ms). Lesson: always verify a pinned test value's underlying arithmetic, not just run-to-green. |
| **`test_dashboard_widget.lua` (3 passed, 19 failed) + `test_api.lua` summary quirk** | Initially alarmed — looked like regressions. | Verified **NOT regressions** by stashing the 6 new untracked files and re-running on clean HEAD: identical failures. `git diff --stat HEAD -- absaudio/ spec/ api.lua config.lua` returned empty (existing tracked files byte-identical). These are pre-existing dashboard-refactoring debt and a pre-existing circular-require quirk in test_api (line 680 `error_handler` reload) — both outside issue #32 scope. |
| **macOS BSD `sed` choked on arithmetic in the test-runner script** | First full-suite run used `sed 's/.*\([0-9]\+\).../...'` — BSD sed doesn't support `\+` in BRE, causing a syntax error that aborted the loop. | Rewrote the runner to use `grep -oE '[0-9]+ passed, [0-9]+ failed'` (portable). |
| **`gitnexus_detect_changes` failed after `gitnexus analyze`** | `analyze` CLI upgraded the LadybugDB file to v41, but the GitNexus MCP gateway reader is built against v40 → "Trying to read a database file with a different version". | Infrastructure version skew between the CLI and the MCP gateway — unfixable by retrying, not a code issue. Scope verified independently via `git status`/`git diff --stat`: purely additive (6 new files, 0 modified tracked files). |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/time_math.lua` (new, 106 lines) | FFmpeg `av_rescale_q` arithmetic: rescale, to_ms, to_seconds, ms_to_seconds, seconds_to_ms, clamp |
| `absaudio/ring_buffer.lua` (new, 158 lines) | Pure PCM ring-buffer index math (immutable absolute-counter state); 11 functions |
| `absaudio/atempo.lua` (new, 63 lines) | FFmpeg atempo filter-chain builder; chains 2.0/0.5 stages for out-of-range speeds |
| `spec/test_time_math.lua` (new, 139 lines) | 18 tests: rescale rounding, 44.1k/90k/NTSC/ms timebases, s↔ms round-trip, clamp, integration |
| `spec/test_ring_buffer.lua` (new, 224 lines) | 15 tests: fill/free/empty/full, overrun/underrun, immutable write/read, wraparound, large capacity |
| `spec/test_atempo.lua` (new, 167 lines) | 20 tests: single-stage presets 0.5–2.0, chaining up (3×/4×/5×/8×), chaining down (0.1/0.25/0.3), error cases |
| `absaudio/AGENTS.md` | Generalized "Pure logic" section into four subsections (chapter_navigator + 3 new modules with API/conventions) |
| `spec/AGENTS.md` | Added test_time_math, test_ring_buffer, test_atempo to the absaudio-modules test-file list |

## Verification

```
luajit spec/test_time_math.lua   → 18 passed, 0 failed
luajit spec/test_ring_buffer.lua → 15 passed, 0 failed
luajit spec/test_atempo.lua      → 20 passed, 0 failed
```

Full suite: all 16 unrelated test files pass unchanged; the 2 pre-existing failures
(test_dashboard_widget, test_api summary) reproduced identically on clean HEAD
with my files stashed — confirmed outside this issue's scope.

No device testing needed — all three modules are pure math. This is by design:
slice A is the Mac-testable core that the device-dependent slices (B onward) build on.

## Open Items & Next Steps

- [ ] **Commit** this work (TDD skill rules: orchestrator did not commit; user triggers it). 6 new files, no tracked-file modifications.
- [ ] **Slice B** (issue #33 or next audio issue): backend contract conformance with the FFI layer stubbed — the new FFmpeg backend satisfies the same transport state-transition table already proven against the stub/inkview backends (`spec/test_player.lua`). Will consume `time_math` (position) and `atempo` (speed graph).
- [ ] **Slice C onward** (device): FFI cdef shim + availability probe, decode producer, output consumer (the ring_buffer module slots in here), transport wiring, live ABS sync. See PRD #31's "Implementation sequencing".
- [ ] **Pre-existing test debt** (not this issue): `test_dashboard_widget.lua` (19 failing) and `test_api.lua` circular-require quirk — should be addressed in a separate housekeeping pass.
- [ ] **GitNexus MCP gateway version skew**: the `detect_changes` MCP tool can't read the v41 DB the `analyze` CLI writes until the gateway is rebuilt. Use the CLI (`npx gitnexus` commands) for change detection in the meantime, or `git status`/`git diff`.

---

*Log written by write-log skill*
