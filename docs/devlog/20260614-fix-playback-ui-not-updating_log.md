# Fix: Playback UI Not Updating (Play Button, Progress Bar, Time Display, Icon Toggle)

> **Date:** 2026-06-14
> **Type:** generic
> **Reference:** N/A (continuous debugging session)

## Goal

Make the audiobook playback UI in the `BookDetailView` widget fully functional in the KOReader emulator: tapping the play button starts playback, the time counter counts up, the progress bar fills, and the play/pause button icon toggles between ▶ and ⏸. Initially, **none** of this worked — tapping play did nothing visible.

## What Was Done

- **`absaudio/widget_helpers.lua` — Play button tap dispatch fix:** `makeTappableButton` assigned a bare `GestureRange` object to `ges_events`, but KOReader's `InputContainer` iterates `ges_events` with `ipairs()` (requires an array). Wrapped it in `{ }` so taps dispatch correctly.
- **`absaudio/progress_bar.lua` — Visual rendering:** Added a `paintTo` method (the widget extended `InputContainer` but had no `paintTo`, so it was invisible). Draws a two-tone bar: light-gray background track + dark-gray fill, vertically centered within the tap-target area.
- **`absaudio/stub_backend.lua` — Real-time wall clock (the core fix):** The stub's virtual clock only advanced via the test-only `_advanceTime()` method, which no production code ever calls — so the position was frozen at zero and every repaint drew identical content. Added a dual time mode: real-time (default) uses `ui/time.to_number(ui/time.now())` for the emulator; calling `_advanceTime()` switches to manual virtual-clock mode for deterministic tests.
- **`absaudio/book_detail.lua` — State-driven UI updates:** `_updatePlaybackDisplay()` now (a) calls `:free()` on the `time_display_widget` and the play button's inner `TextWidget` to invalidate KOReader's bitmap cache, (b) toggles the play/pause icon (▶ stopped/paused, ⏸ playing) via `player:getState()`, (c) calls `UIManager:setDirty(target, "full")` to force a repaint. Stored a `self.play_btn` reference for icon updates.
- **Tests added:** `test_player.lua` +2 (real-time mode + `_advanceTime` switching); `test_book_detail.lua` +1 (icon toggle across play/pause/resume). Totals: 75 player + 43 book_detail pass.
- **Stripped all `[DIAG]` diagnostic logging** added during investigation.

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Dual-mode (`use_real_time` flag) instead of a separate emulator backend | One `use_real_time` flag (default true, false after first `_advanceTime` call) keeps the stub's public API identical. Tests get deterministic manual control; the emulator gets real wall-clock progression. Avoids duplicating the backend class. |
| Icon toggle in `_updatePlaybackDisplay()` | Centralizes all state-driven UI updates in one function that already runs on every 0.5s update cycle. Avoids duplicating logic in `_onPlayPause`. |
| `bb:paintRect` for the progress bar (two manual rects) | Simplest e-ink-friendly approach; no rounded-rect / anti-alias dependency. Vertical centering handles the larger tap-target dimen. |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| Time counter never advanced; UI appeared frozen | Stub backend's virtual clock (`sim_time`) only advanced via test-only `_advanceTime()`, never called by production code → `getPosition()` always returned the start position | Added real-time mode using wall-clock (`ui/time`); `_advanceTime()` switches to manual mode for tests |
| `ui/time.now()` crash: "attempt to index local 't' (a number value)" | `time.now()` returns an fts-encoded **number**, not a table — code tried `t.sec + t.usec/1000000` | Use `time.to_number(time.now())` (returns float seconds, 4-decimal precision) |
| Play button tap did nothing | `ges_events[tap_event_name]` was a bare `GestureRange` object; `InputContainer` uses `ipairs()` which needs an array | Wrapped in `{ }` |
| Progress bar invisible | `InputContainer` subclass had no `paintTo` method | Added a `paintTo` drawing background + fill rects |
| Time text didn't update despite position changing | `TextWidget` caches its rendered bitmap; changing `.text` alone leaves stale pixels | Call `:free()` on the TextWidget after setting new text, before `setDirty` |
| "arithmetic on 'struct BlitBufferRGB32' and 'number'"; "paintRoundedRect (a nil value)" — appeared to be a broken BlitBuffer build | **Closure signature bug:** a diagnostic `self.paintTo = function(bb, x, y)` (missing `self`) caused a colon-call parameter shift — `widget:paintTo(bb,x,y)` expands to `widget.paintTo(widget, bb, x, y)`, so `bb` got the widget, `x` got the BlitBuffer. The BlitBuffer was never broken. | Removed the broken diagnostic wrapper; restored the original `FrameContainer`. **Always** include `self` when overriding a method via closure. |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/widget_helpers.lua` | Array-wrap `GestureRange` in `makeTappableButton` ges_events (tap dispatch fix) |
| `absaudio/progress_bar.lua` | Add `paintTo` (two-tone bar, vertically centered) |
| `absaudio/stub_backend.lua` | Dual time mode: real-time wall clock (default) + manual virtual clock (tests) |
| `absaudio/book_detail.lua` | TextWidget `:free()` cache invalidation; play/pause icon toggle; `setDirty("full")`; `self.play_btn` ref |
| `spec/test_player.lua` | +2 tests (real-time mode, `_advanceTime` switching) |
| `spec/test_book_detail.lua` | +1 test (icon toggle across play/pause/resume) |
| `AGENTS.md` | Added learnings: TextWidget bitmap cache, `ui/time` API, colon-call closures; + log index entry |

## Open Items & Next Steps

- [ ] Confirm icon toggle renders correctly on real device (emulator confirmed; glyph rendering may vary)
- [ ] Test on real device with the inkview backend (real audio playback, not the stub)
- [ ] Consider `IconWidget` for play/pause icons if `TextWidget` glyph rendering is inconsistent across devices
- [ ] Pre-existing `test_library_browser.lua` failure (InfoMessage nil) is unrelated to this work and still open

---

*Log written by write-log skill*
