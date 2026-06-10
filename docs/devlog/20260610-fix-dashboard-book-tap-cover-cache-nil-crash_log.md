# Fix: Dashboard book tap crashes — cover_cache nil cache_dir

> **Date:** 2026-06-10
> **Type:** generic
> **Reference:** Crash report from emulator

## Goal

Fix the crash that occurs when tapping a downloaded book on the dashboard. The emulator crashed with:
```
cover_cache.lua:45: attempt to concatenate upvalue 'cache_dir' (a nil value)
```

## What Was Done

- Added `cover_cache.isInitialized()` guard function to `cover_cache.lua`
- Added `cover_cache.init()` call to `detail.prepare()` in `book_detail.lua`, making cover cache initialization happen before any `BookDetailView` is created regardless of navigation path
- Added `isInitialized` and `init` stubs to the `cover_cache` mock in `test_book_detail.lua`
- All 311 tests pass across the full suite

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Init cover_cache in `detail.prepare()` instead of only in `browser.prepare()` | `detail.prepare()` is the shared entry point for book detail rendering from any navigation path (dashboard tap, library browser tap, future paths). This ensures cover_cache is always initialized before `BookDetailView:init()` runs. |
| Added `isInitialized()` idempotent guard | Prevents double initialization when entering via library browser (which already calls `cover_cache.init()` in `browser.prepare()`). Second call is a no-op. |
| Did NOT remove the existing init in `browser.prepare()` | The library browser itself may need cover_cache initialized before book detail is pushed (e.g., for cover thumbnails in the browser list). Keeping both calls is safe with the guard. |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| `attempt to concatenate upvalue 'cache_dir' (a nil value)` at `cover_cache.lua:45` | `cover_cache.init(cache_dir)` was only called in `library_browser.lua`'s `browser.prepare()`. Dashboard's `_onBookTap` pushes directly to `nav.push("detail")` → `detail.prepare()` → `BookDetailView:init()` → `hasCachedCover()` → `getCoverPath()` — never initializing the cache. | Added `cover_cache.init()` to `detail.prepare()` with `isInitialized()` guard. |
| Tests failed with `attempt to call nil field 'isInitialized'` | The `cover_cache` mock in `test_book_detail.lua` didn't include the new `isInitialized` function. | Added `isInitialized` and `init` stubs to the mock. |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/cover_cache.lua` | Added `isInitialized()` function (returns `cache_dir ~= nil`) |
| `absaudio/book_detail.lua` | Added `cover_cache.init()` call in `detail.prepare()` with idempotent guard |
| `spec/test_book_detail.lua` | Added `isInitialized` and `init` stubs to cover_cache mock |

## Open Items & Next Steps

- [ ] Dashboard does not yet show cover images — adding them will be a future task; cover_cache is now ready for it
- [ ] Consider whether `browser.prepare()` init call can be removed now that `detail.prepare()` handles it (low priority, harmless duplication)

---

*Log written by write-log skill*
