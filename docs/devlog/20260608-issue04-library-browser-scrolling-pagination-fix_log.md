# Library browser scrolling and pagination fix

> **Date:** 2026-06-08
> **Type:** issue
> **Reference:** Issue #4 — Library browser follow-up (scrolling + pagination)

## Goal

Fix two non-functional features in the library browser: scrolling (swipe to scroll the book list) and pagination (navigate between pages of results).

## What Was Done

- **Removed `ges_events.Swipe` registration** from `LibraryBrowserView:init()` — the view was intercepting ALL swipe events and returning `true`, preventing `ScrollableContainer` from ever receiving them.
- **Removed `onSwipe` handler** — was handling swipe-down-to-close (replaced by Back key/button only).
- **Adopted KOReader's `cropping_widget` pattern** — renamed `self.scrollable` to `self.cropping_widget`, added `show_parent = self` on the ScrollableContainer so that its `UIManager:setDirty(self.show_parent, ...)` calls target the top-level widget. Without this, scroll repaints were silently discarded as "not painting covered widget(s)".
- **Replaced "Load more…" button** with a **← Prev / Page X/Y / Next →** navigation bar. The old button was unreachable (below the fold, no scrolling), forward-only, and replaced the entire view. New nav bar shows disabled (gray) buttons when at boundary, only renders when multiple pages exist.
- **Added `onPrevPage` and `onNextPage` handlers** replacing the old `onLoadMore`.
- **Restored accidentally deleted methods** — `onClose`, `onCycleSort`, `onSearch`, and `onBookTap` were lost during a large `replace_lines` edit and had to be re-inserted.

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Use `cropping_widget` + `show_parent = self` pattern | This is the official KOReader pattern (see `bookmapwidget.lua`). Without `show_parent`, `ScrollableContainer` calls `UIManager:setDirty(nil, ...)` which triggers "not painting covered widget(s)" — the repaint is silently swallowed. |
| Remove swipe-to-close entirely | Swipe events must propagate to `ScrollableContainer` for scrolling. Close via Back key (`key_events.Close`) or the ← Back button in the header. This is standard KOReader UX. |
| Page nav bar instead of "Load more" | "Load more" was unreachable without scrolling (chicken-and-egg). Page nav provides bidirectional navigation, shows current position, and is visible at the bottom of each page. |
| Page nav hidden when only one page | Avoids visual clutter when the library fits on one screen. |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| Scrolling didn't work even after removing `ges_events.Swipe` | `ScrollableContainer` uses `UIManager:setDirty(self.show_parent, ...)` to trigger repaints. Without `show_parent = self`, it called `setDirty(nil, ...)` → "not painting covered widget(s)" → repaint silently discarded. | Set `show_parent = self` on the ScrollableContainer and store it as `self.cropping_widget` (KOReader's official pattern from `bookmapwidget.lua`). |
| `replace_lines` edit consumed too many lines | The start/end anchors for the `_addLoadMore` → `_addPageNav` replacement spanned into the navigation handlers section, deleting `onClose`, `onCycleSort`, `onSearch`, and `onBookTap`. | Re-inserted all four methods with `insert_after` edits. Verified with `grep` for all `function LibraryBrowserView:` entries. |
| Emulator at 1264×1680 showed only 1264×969 | SDL caps window height to available display space on macOS. The `kodev run -W/-H` flags also don't work due to macOS `getopt` incompatibility. | Reverted to default 540×720. The fix works at any resolution. |
| `setDirty via a func from widget nil` in logs | Confirmed the missing `show_parent` — the ScrollableContainer's `show_parent` was nil, so `setDirty` received nil as the widget argument. | Fixed by `show_parent = self`. |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/library_browser.lua` | Removed `ges_events.Swipe` + `onSwipe`; renamed `self.scrollable` → `self.cropping_widget` with `show_parent = self`; replaced `_addLoadMore` → `_addPageNav` with Prev/Next buttons; added `onPrevPage`/`onNextPage` handlers |

## Test Results

75 tests, 0 failures (all existing tests pass unchanged).

## Open Items & Next Steps

- [ ] **Emulator visual verification** — Scrolling and pagination confirmed working at 540×720. Should also verify on device.
- [ ] **`main.lua:195` error** — `onSaveSettings` crashes with `attempt to index local 'fields' (a nil value)`. Non-fatal but should be fixed.
- [ ] **Consider `ignore_events`** — `bookmapwidget.lua` uses `ignore_events = {"swipe"}` on ScrollableContainer to prevent double-handling. We don't need this since we removed our own swipe handler, but worth noting for future reference.
- [ ] **Large library performance** — Current implementation fetches ALL items (`limit = 0`) on first load and does client-side pagination. For very large libraries this could be slow. Consider server-side pagination as a future optimization.

---

*Log written by write-log skill*
