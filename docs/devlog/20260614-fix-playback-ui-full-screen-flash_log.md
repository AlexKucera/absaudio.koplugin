# Fix: Playback UI Full-Screen Flash on Every Update

> **Date:** 2026-06-14
> **Type:** generic
> **Reference:** N/A (device-reported regression)

## Goal

On the real device (PB700K3), the audiobook playback UI forced a full-screen e-ink black-flash on every 0.5s progress update, making playback ugly and flickery. The native PocketBook audiobook player does not exhibit this. Eliminate the flashing while keeping the UI updating.

## What Was Done

- **`absaudio/book_detail.lua` — refresh mode fix:** `_updatePlaybackDisplay()` (the function invoked on every ~0.5s playback tick) called `UIManager:setDirty(target, "full")`. `"full"` triggers a full black-then-white e-ink refresh across the entire screen — the flash. Changed the mode to `"partial"`, which repaints the region without the full-screen flash, matching the native player. `"full"` is now reserved for widget swaps/transitions (where a clean full repaint is correct).

No other code changed. This is a one-line behavioral fix at the refresh boundary.

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| `"partial"` (not `"ui"`/region rect) | The simplest non-flashing mode. KOReader maps `"partial"` to a non-flashing update; a region rectangle would be more precise but requires tracking exact dirty widget geometry, and the existing TextWidget `:free()` invalidation already keeps repaints bounded. The native player's progress tick is itself a partial refresh. |
| Left `"full"` at the widget-swap call sites | The prior devlog (`20260609-issue04-library-browser-search-partial-repaint-fix_log.md`) deliberately added `"full"` for search/widget swaps where stale framebuffer content is the failure mode. That is correct there — the bug was only reusing `"full"` for a high-frequency periodic tick. |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| Full-screen flash every 0.5s during playback | Periodic `_updatePlaybackDisplay()` used `setDirty(target, "full")`; `"full"` = full e-ink refresh (black flash) | Use `"partial"` for periodic repaints; reserve `"full"` for widget swaps |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/book_detail.lua` | `_updatePlaybackDisplay()`: `setDirty(target, "full")` → `"partial"` + explanatory comment |

## Verification

- `busted spec/test_book_detail.lua` → **51 passed, 0 failed**.
- Full suite (`busted -p lua spec/`) → **366 passed**; only the 7 pre-existing `InfoMessage nil` failures in `test_library_browser` remain (unrelated, documented open in prior devlog). The test mock `setDirty = function() end` ignores the mode argument, so the change is isolated.

## Open Items & Next Steps

- [ ] Confirm on PB700K3 that the partial refresh no longer flashes during playback (emulator cannot show e-ink flash behavior).
- [ ] Related issues diagnosed in same session (separate commits): (1) no audible sound — `create_from_manifest()` never selects the inkview backend, defaulting to the stub; inkview FFI cdefs are fabricated vs. real `inkview.h`. (2) downloaded file not findable in Finder — it went to `/tmp/audiobooks/...` because `download_dir` was unset at download time.

---

*Log written by write-log skill*
