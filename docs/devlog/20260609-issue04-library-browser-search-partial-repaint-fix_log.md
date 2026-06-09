# Library Browser Search: Partial Repaint Fix

> **Date:** 2026-06-09
> **Type:** issue
> **Reference:** Issue #4 — Library browser search feature

## Goal

Fix the library browser search rendering bug: after entering a search term (e.g. "sanderson"), the search results rendered as a partial overlay on top of the old (unfiltered) book listing instead of replacing it. The old content persisted in the framebuffer, and only a small region of the screen showed matching results.

## What Was Done

- Diagnosed the root cause: `LibraryBrowserView:_refresh()` swaps the widget via `UIManager:close()` + `UIManager:show()` but did not explicitly request a full-screen repaint. On e-ink devices, the default refresh mode is `fast` (partial), so only changed regions are repainted — the old widget's pixel content remains in the framebuffer.
- Added `UIManager:setDirty(_view, "full")` after `UIManager:show(_view)` in `_refresh()` to force a complete screen clear and full redraw.
- Added a verbose log line in `_addBookList()` reporting the item count returned by `getItems()` for future debugging.
- Verified all 25 tests still pass (5 browser + 20 store).

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Use `setDirty(_view, "full")` instead of `"ui"` mode | E-ink devices need full refresh to clear old framebuffer content. `"ui"` mode is still partial and would leave artifacts. |
| Single-line fix in `_refresh()` rather than per-call-site | All 6 callers of `_refresh()` (search, sort, pagination, cover fetch) go through the same method, so the fix applies universally. |
| Keep the `_addBookList` item count log | Low cost, high diagnostic value — confirms whether the filter is working at the data layer vs rendering layer. |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| Search results appeared as partial overlay on old content | `_refresh()` closed old widget and showed new one without requesting full-screen repaint. KOReader's default `fast` mode only redraws changed regions on e-ink, leaving stale framebuffer pixels. | Added `UIManager:setDirty(_view, "full")` after `UIManager:show(_view)` in `_refresh()`. |
| `"not painting 1 covered widget(s)"` in device logs | Misleading but normal — UIManager skips painting widgets fully covered by a fullscreen widget on top. Not related to the bug. | N/A (red herring). |
| Test suite shows `pcall FAILED: attempt to perform arithmetic on a nil value (field 'w')` at line 248 | `_addHeader()` accesses `Screen`/`Size` globals not available in test harness. Only affects tests — works fine on device where these globals exist. | Pre-existing; not addressed in this session. |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/library_browser.lua` | Added `UIManager:setDirty(_view, "full")` in `_refresh()` (line 592); added item count log in `_addBookList()` (line 313) |

## Open Items & Next Steps

- [ ] Verify on device that search results render correctly with full clear
- [ ] Verify pagination (Prev/Next) still works after the `setDirty("full")` change
- [ ] Verify sort change also triggers full repaint correctly
- [ ] The scheduled cover fetch callback (0.5s after `show()`) calls `_view:_refresh()` — this now also gets `full` refresh; confirm no performance regression on e-ink

---

*Log written by write-log skill*
