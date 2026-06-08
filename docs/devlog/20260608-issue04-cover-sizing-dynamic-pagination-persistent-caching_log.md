# Issue #4: Cover sizing, dynamic pagination, persistent cover caching

> **Date:** 2026-06-08
> **Type:** issue
> **Reference:** Issue #4 — Library browser follow-up (cover sizing, pagination, caching)

## Goal

Fix cover images rendering too small on device, make page size fit the screen exactly (no scrolling between pages), download all covers upfront with persistent caching, and add a "Clear cover cache" button in settings.

## What Was Done

- **DPI-scaled cover thumbnails** in `_addBookRow`: `row_height` 80→`Screen:scaleBySize(100)`, `thumb_width` 60→`Screen:scaleBySize(80)`, `thumb_height` 80→`Screen:scaleBySize(100)`
- **Bumped book info text** from `cfont 14` to `cfont 16` (fixed size, not DPI-scaled — user wanted slight increase, not 2×)
- **DPI-scaled placeholder icon** from `cfont 20` to `cfont Screen:scaleBySize(22)`
- **Dynamic page size** via `_getPerPage()` — measures actual header widgets in `content_group` for height, estimates nav bar (`Size.padding.large * 2 + 30`), computes `floor((screen_height - used - nav) / row_height)`. Replaced all three hardcoded `per_page = 25` with `self:_getPerPage()`.
- **Fetch ALL covers upfront** — rewrote `_scheduleCoverFetch()` to call `library_store.getItems({page=1, per_page=9999})` and download covers for every item, skipping already-cached ones.
- **Persistent cache directory** — changed from `/tmp/abs_covers` to `DataStorage:getSettingsDir() .. "/absaudio_covers"` (resolves to `./settings/absaudio_covers` in KOReader runtime).
- **"Clear cover cache" button** added to settings dialog (`MultiInputDialog` buttons table) — calls `browser.clearCoverCache()`, shows InfoMessage with count deleted.
- **Fixed mkdir in cover_cache.lua** — path splitting on `./settings/absaudio_covers` produced empty string → joined as `"/"` → attempted to create root directory. Fix: skip `"."` parts when iterating path components.

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Fixed text size (16) not DPI-scaled | User tested DPI-scaled text (`Screen:scaleBySize(18)`) and it was "HUGE". Fixed 16pt is slightly larger than the original 14pt without being overwhelming on device. |
| DPI-scaled cover dimensions | Covers were "way too small" on device. DPI scaling makes them proportional to screen density. |
| Dynamic per_page instead of fixed 7 | User suggested 7 items per page, but this would waste space on larger screens. Dynamic calculation adapts to any device — measures actual header height and estimates nav bar. |
| Persistent cache, no TTL | User said "how often do I change the images? probably never." A clear-cache button in settings is simpler and more predictable than TTL-based expiry. |
| `DataStorage:getSettingsDir()` for cache | KOReader's standard persistent storage location. Previous `/tmp` was cleared between sessions. |
| Fetch all covers upfront (per_page=9999) | ~200 items is fast. Avoids re-downloading on each page navigation. Already-cached items are skipped instantly. |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| `'}' expected near 'UIManager'` syntax error in main.lua | Missing closing `}` for the "Clear cover cache" button row — `insert_after` placed content inside the previous row's table | Added proper `},` closing brace for the new button row and `}` for the containing table |
| `Read-only file system` when creating `./settings/absaudio_covers` | `cover_cache.fetchAndCache` mkdir loop splits `./settings/absaudio_covers` → `["", ".", "settings", "absaudio_covers"]`. Empty string joined as `"/"` → tried to create root `/settings` | Skip `"."` parts in path splitting. Relative paths now build correctly: `settings/` → `settings/absaudio_covers` |
| DPI-scaled font was "HUGE" | `Screen:scaleBySize(18)` on a 300 DPI device = ~38pt equivalent. User only wanted 15-16pt. | Changed from `Screen:scaleBySize(18)` to fixed `16` |
| `_getPerPage` used fixed header estimate | Header height varies with font size and padding. A fixed estimate would be wrong on different devices | Measure actual `content_group` widget heights at runtime, only estimate the nav bar that hasn't been added yet |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/library_browser.lua` | DPI-scaled cover dimensions; text 14→16; added `_getPerPage()` with dynamic calculation; rewrote `_scheduleCoverFetch` to fetch all covers; persistent cache dir; added `clearCoverCache()` function |
| `absaudio/cover_cache.lua` | Fixed mkdir to skip `"."` path components, preventing root filesystem write attempt |
| `main.lua` | Added "Clear cover cache" button to settings dialog |

## Test Results

75 tests, 0 failures (all existing tests pass unchanged).

## Open Items & Next Steps

- [ ] **Verify on device** — DPI-scaled covers and dynamic page size need real device testing
- [ ] **Cover fetch progress indicator** — Currently no UI feedback while downloading ~200 covers. Consider a spinner or progress bar.
- [ ] **`main.lua:195` error** — `onSaveSettings` still crashes with `attempt to index local 'fields' (a nil value)`. Non-fatal but should be fixed.
- [ ] **Large library performance** — `per_page=9999` loads all items into memory. For 1000+ item libraries this could be slow. Consider streaming or batching.

---

*Log written by write-log skill*
