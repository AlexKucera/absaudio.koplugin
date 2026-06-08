# Issue #4 — Library browser: fix "Unknown Title", cover art caching, and lfs loading

> **Date:** 2026-06-08
> **Type:** issue
> **Reference:** Issue #4 — Library browser + Book detail view

## Goal

Fix three blocking gaps in the library browser that prevented emulator testing from passing:
1. All book titles showed "Unknown Title" — data mapping bug
2. Cover art never appeared — `:` vs `.` method call bug + lfs not loading
3. Cover cache directory never created — `lfs` module not available in KOReader env

## What Was Done

- **`absaudio/library_store.lua`** — Added `_get_item_title()` / `_get_item_author()` helper functions that read `item.media.metadata.title` / `item.media.metadata.authorName` (real ABS API shape), falling back to `item.title` / `item.author`. Updated `filter_items()` and all 4 title/author sort modes to use these helpers. Exported as public `library_store.getItemTitle()` / `library_store.getItemAuthor()` API for use by library_browser.
- **`absaudio/library_browser.lua`** — Changed `_addBookRow()` to use `library_store.getItemTitle(item)` / `library_store.getItemAuthor(item)` instead of direct field access. Replaced per-row `scheduleIn(0.5, cover_cache.fetchAndCache)` with batch `_scheduleCoverFetch()` that fetches all uncached covers for the current page then calls `_view:_refresh()`.
- **`absaudio/cover_cache.lua`** — Three fixes:
  1. `api:getCover()` → `api.getCover()` — `:` passed `api` as `self`, shifting all args by one position; sink was always nil.
  2. `lfs` loading — changed from single `pcall(require, "lfs")` to dual-path: try `require` first, fall back to `_G.lfs` (KOReader provides lfs as a global built into LuaJIT, not as a loadable module).
  3. Recursive mkdir — replaced single `lfs.mkdir(cache_dir)` with path-component-by-component mkdir (`mkdir -p` equivalent) that checks each segment and reports failures.
- **`spec/test_library_store.lua`** — Updated `SAMPLE_ITEMS` to use real ABS API shape (`media.metadata.title` / `media.metadata.authorName` instead of flat `title` / `author`). Updated all assertions to use `library_store.getItemTitle()` / `library_store.getItemAuthor()` instead of direct field access.
- **`spec/test_cover_cache.lua`** — Updated mock `getCover` signatures from `function(self, item_id, sink)` to `function(item_id, sink)` to match the `.` call. Added test for recursive nested directory creation.

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Dual-path lfs loading (`require` + `_G.lfs` fallback) | KOReader builds lfs into LuaJIT as a global. `pcall(require, "lfs")` fails in the KOReader emulator. Tests use `package.loaded["lfs"]` so `require` works there. Both paths are needed. |
| Recursive mkdir instead of single `lfs.mkdir` | `lfs.mkdir` only creates leaf directories. If cache_dir is `/tmp/abs_covers` and `/tmp` exists but `/tmp/abs_covers` doesn't, single mkdir should work — but in practice it failed silently. Recursive approach is robust and handles any nesting. |
| Batch cover fetch instead of per-row | Per-row `scheduleIn(0.5, ...)` fired N times with no view refresh after completion. Batch approach: fetch all uncached covers for current page in one scheduled callback, then `_view:_refresh()` once. Simpler, fewer timer callbacks. |
| Helpers in library_store, not library_browser | Data extraction logic (title/author from nested metadata) belongs in the data layer. library_browser is pure UI composition. Enables reuse by book_detail and test assertions. |
| Test data updated to match real API shape | Tests were using flat `item.title` / `item.author` which masked the data mapping bug. Now tests validate the same code path the real API triggers. |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| All titles show "Unknown Title" in emulator | ABS API returns `item.media.metadata.title`, not `item.title`. library_store filter/sort and library_browser used direct field access which was always nil. | Added `_get_item_title()` / `_get_item_author()` helpers that check nested path first, fallback to flat field. |
| Covers never fetched | `api:getCover(item_id, file_sink)` — `:` passes `api` as `self`, so `item_id` became the sink param and `file_sink` was nil. Cover was never written to disk. | Changed `:` to `.` — `api.getCover(item_id, file_sink)` |
| Cover cache dir `/tmp/abs_covers` never created | `lfs` not available via `require("lfs")` in KOReader. It's a global (`_G.lfs`). `pcall(require, "lfs")` fails → `lfs_ok = false` → entire mkdir block skipped → `io.open` fails with "No such file or directory". | Dual-path lfs loading: try `require` first, fall back to `_G.lfs`. |
| `lfs.mkdir` fails silently | Single `lfs.mkdir("/tmp/abs_covers")` may fail if parent doesn't exist or on permission issues, and return value was never checked. | Recursive mkdir with return value checking and error logging. |
| Test mock `getCover` had `self` param | Tests were written to match the old `:` call style. After fixing to `.`, the mock's `self` param consumed `item_id`, shifting remaining args. | Updated all mock `getCover` signatures to `function(item_id, sink)`. |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/library_store.lua` | Added `_get_item_title`/`_get_item_author` helpers; updated filter + sort to use them; exported as public API |
| `absaudio/library_browser.lua` | Uses `library_store.getItemTitle`/`getItemAuthor` for display; batch cover fetch replaces per-row |
| `absaudio/cover_cache.lua` | Fixed `:` → `.` on `api.getCover`; dual-path lfs loading; recursive mkdir |
| `spec/test_library_store.lua` | SAMPLE_ITEMS now use `media.metadata.title/authorName`; assertions use public helpers |
| `spec/test_cover_cache.lua` | Fixed mock `getCover` signatures; added recursive mkdir test |

## Test Results

75 tests, 0 failures across 6 spec files:
- test_config: 12
- test_cover_cache: 7 (was 6, +1 recursive mkdir test)
- test_error_handler: 20
- test_library_store: 20
- test_logger: 7
- test_manifest: 9

## Open Items & Next Steps

- [ ] **Emulator re-test** — Verify titles show correctly and covers load with the lfs fix (`_G.lfs` fallback)
- [ ] **Device test** — Test on real KOReader device to confirm lfs availability
- [ ] **Cover refresh UX** — Verify batch fetch + `_refresh()` doesn't cause visible flicker or scroll position reset
- [ ] **Remove debug prints** — `[ABS-DEBUG]` and `[ABS-BROWSER]` print statements still present
- [ ] **Search/sort verification** — Now that title/author extraction is fixed, verify search and sort work in emulator
- [ ] **Book detail view** — `get_item_title`/`get_item_author` in book_detail.lua already use correct helpers; verify detail view works end-to-end

---

*Log written by write-log skill*
