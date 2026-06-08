# Issue #4 — Library Browser + Book Detail View

> **Date:** 2026-06-08
> **Type:** issue
> **Reference:** Issue #4 — Library browser + Book detail view

## Goal

Implement the full navigation flow for Issue #4: Dashboard → Library Browser (with search, sort, pagination) → Book Detail View. This includes both data layer modules (with unit tests) and UI widget modules (for emulator/device testing).

## What Was Done

- **cover_cache.lua** — Data layer module for fetching and caching cover art from ABS. Implemented with TDD: 6 tests covering init, getCoverPath, hasCachedCover (hit/miss), fetchAndCache (success, API failure, cache skip).
- **cover_cache test rewrite** — Rewrote test_cover_cache.lua to use pure mock file system (luajit doesn't ship with `lfs`). Mock tracks `_existing_files`, `_existing_dirs`, `_mkdir_called`. `io.open` is mocked per-test for write operations.
- **library_store.lua** — Data layer module for fetching all library items from ABS and providing client-side search, sort, and pagination. Implemented via subagent with TDD: 20 tests covering init, fetchAll, isLoaded, getItems (pagination, search by title/author, 6 sort modes), getSortModes, setSort/getCurrentSort.
- **library_browser.lua** — Fullscreen UI widget for browsing the library. Shows book list with cover thumbnails, title/author/duration, progress indicators. Features: header with back/sort/search buttons, InputDialog for search, sort cycling through 6 modes, "Load more" pagination, background cover fetching.
- **book_detail.lua** — Fullscreen UI widget for book detail view. Shows cover art, metadata (title, author, duration), audio files with preferred format highlighting, ebook files section, tappable chapter list with time ranges, download status badge. Falls back to manifest data when offline.
- **dashboard_widget.lua** — Updated `_onBrowseLibrary` to wire up the full navigation flow: Dashboard → Library Browser → Book Detail → Back. Shows library browser first, then schedules dashboard close.
- **main.lua** — **Critical fix**: Added `api.init()` call in `ABSAudio:init()` and after settings save. Previously `api.init()` was never called, so `api.is_configured()` always returned `false`.

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Pure mock file system for cover_cache tests | luajit doesn't ship with `lfs` module. Rather than installing it, we mock `lfs.attributes`, `lfs.mkdir`, and `io.open` entirely. Tests are fast and don't touch real disk. |
| Subagents for library_store + UI widgets | library_store has testable logic (20 tests) — good subagent task. UI widgets are boilerplate-heavy KOReader widget code — subagents handle the volume while we focus on wiring. |
| Synchronous API calls in browser.show() | Originally used `UIManager:scheduleIn(0.1, ...)` but KOReader swallows errors inside scheduled callbacks silently. Switched to synchronous pcall with error display. |
| library_browser.show() before dashboard close | Calling `self:onClose()` first destroyed the widget context, preventing subsequent `library_browser.show()` from executing. Fixed by showing browser first, then scheduling dashboard close via `scheduleIn(0.05, ...)`. |
| No unit tests for UI widgets | KOReader UI widgets require the full runtime (Screen, UIManager, FocusManager). These are tested in the emulator, not via luajit unit tests. |
| Separate data layer from UI | library_store handles all data logic (fetch, cache, filter, sort, paginate). library_browser is pure UI composition. Enables unit testing the data layer independently. |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| Library browser never opens — InfoMessage appears but nothing else | `api.init(server_url, token)` was **never called** in main.lua. `api.is_configured()` always returned `false`, so `_onBrowseLibrary` hit the early `error_handler.show("auth", ...)` return. | Added `api.init()` call in `ABSAudio:init()` reading server/token from config, and re-init after settings save. |
| `[ABS-BROWSER] show() called` never printed despite `has_library_browser=true` | Dashboard called `self:onClose()` **before** `library_browser.show()`. Closing the dashboard destroyed the widget mid-method, preventing subsequent code from executing. | Reversed order: call `library_browser.show()` first, then `UIManager:scheduleIn(0.05, function() UIManager:close(dashboard_view) end)` |
| `scheduleIn` callbacks silently swallowing errors | KOReader's `UIManager:scheduleIn` wraps callbacks but doesn't surface Lua errors to the log. If a pcall inside scheduleIn fails, nothing is logged. | Removed scheduleIn for API calls, used direct synchronous pcall. Added `print()` statements for debugging (always visible in crash.log/stdout). |
| Worker 2 (library_browser) subagent failed with "Connection error" | Subagent lost connection during execution, leaving library_browser.lua unimplemented. | Implemented library_browser.lua directly in the main session. |
| `api.getLibraries()` response shape mismatch | Code did `local ok, libraries = api.getLibraries()` and treated `libraries` as an array. But the API returns `true, {libraries = [...]}` — a table with a `libraries` key. | Fixed: `local api_ok, data = api.getLibraries(); local libraries = (data and data.libraries) or {}` |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/cover_cache.lua` | New — cover art fetch + cache module (94 lines) |
| `spec/test_cover_cache.lua` | New — 6 tests with pure mock file system |
| `absaudio/library_store.lua` | New — data layer with fetchAll, getItems, search, sort, pagination (188 lines) |
| `spec/test_library_store.lua` | New — 20 tests covering all data layer functionality |
| `absaudio/library_browser.lua` | New — fullscreen library list widget (681 lines) |
| `absaudio/book_detail.lua` | New — fullscreen book detail widget (750 lines) |
| `absaudio/dashboard_widget.lua` | Updated `_onBrowseLibrary` to wire Dashboard→Browser→Detail navigation |
| `main.lua` | Added `api.init()` in `ABSAudio:init()` and after settings save |

## Test Results

74 tests, 0 failures across 6 spec files:
- test_config: 12
- test_cover_cache: 6
- test_error_handler: 20
- test_library_store: 20
- test_logger: 7
- test_manifest: 9

## Open Items & Next Steps

- [ ] **Emulator testing** — Verify library browser opens and displays books from ABS server (the `api.init()` fix should resolve the blocking issue)
- [ ] **Cover art background fetch** — `UIManager:scheduleIn(0.5, ...)` in `_addBookRow` needs testing; covers should load after initial list render
- [ ] **book_detail API integration** — Test `api.getItemDetails()` → expanded data flow (audioFiles, chapters)
- [ ] **Remove debug prints** — `[ABS-DEBUG]` and `[ABS-BROWSER]` print statements should be removed once stable
- [ ] **Navigation depth** — The on_back/on_book_tap callbacks have deeply nested re-open logic. Consider a simple navigation stack or router pattern.
- [ ] **Error in scheduleIn for dashboard close** — The `UIManager:scheduleIn(0.05, function() UIManager:close(dashboard_view) end)` could fail silently if dashboard_view is already closed

---

*Log written by write-log skill*
