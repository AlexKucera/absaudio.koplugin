# Issue #4 — Library browser: search feature UI exposure and TDD

> **Date:** 2026-06-09
> **Type:** issue
> **Reference:** Issue #4 — Library browser + Book detail view (search portion)

## Goal

Expose the search feature in the library browser UI so users can filter the book list by title/author. The search data layer (`library_store.filter_items`, `getItems({search=...})`) was already implemented and tested, but the search button was invisible in the emulator (emoji 🔍 didn't render) and the `onSearch` callback had a closure scoping bug.

## What Was Done

- **Created `spec/test_library_browser.lua`** — new test file with 5 tests covering browser-level search behavior via TDD (tracer bullet + incremental loop).
- **Added `browser.search(query)`** — public API that sets `_search_query`, resets `_current_page` to 1, and calls `_view:_refresh()`. Single entry point used by both `onSearch` Search button and Clear button.
- **Added `browser.getState()`** — returns `{search_query, current_page}` for testability and external inspection.
- **Added `browser._setSearchQuery()` / `_setCurrentPage()`** — test-only helpers for setting module-local state from outside.
- **Replaced invisible 🔍 emoji with KOReader built-in icon** — `IconWidget` using `appbar.search` (magnifying glass SVG from `resources/icons/mdlight/`). When a search query is active, the query text appears in blue next to the icon.
- **Fixed Lua closure scoping bug** — `local input_dialog = InputDialog:new{...}` where closures inside the table literal couldn't reference `input_dialog` (it wasn't declared yet when closures were created). Split into `local input_dialog; input_dialog = InputDialog:new{...}`.
- **Refactored `onSearch` callbacks** — Search and Clear buttons now call `browser.search(query)` / `browser.search("")` instead of duplicating `_search_query = ...; _current_page = 1; self:_refresh()`.
- **Added debug logging** in `_addBookList` to trace search query flow for diagnosing the unresolved filtering issue.

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Use KOReader's built-in `appbar.search` icon instead of Lucide SVG | Icon already available in KOReader's `resources/icons/mdlight/`, no extra files to bundle, consistent with KOReader UI conventions. `IconWidget` resolves icon names from built-in directories. |
| `browser.search(query)` as single entry point | Eliminates duplication between `onSearch` Search callback and Clear callback. Both go through one function that sets state + refreshes view. Easier to test. |
| `browser.getState()` for testability | `_search_query` and `_current_page` are module-level locals — inaccessible from test files. Public getter exposes state without breaking encapsulation. |
| Mock `library_store` with search filtering in tests | The browser test file uses a mock `getItems` that implements title/author filtering, matching the real store's behavior. This lets browser-level integration tests verify search→filter→result without depending on the real store module. |
| Widget stubs auto-init `ges_events`/`key_events` | KOReader widgets expect these tables to exist. Stub `new()` pre-populates them so `LibraryBrowserView:init()` doesn't crash on `ges_events.TapBack = {...}` etc. |
| Class stub's `new` calls `init()` | KOReader's real `Widget:new` calls `init()`. Without this, `_refresh()` → `LibraryBrowserView:new{}` never triggers `_addBookList()`. |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| Search button invisible in emulator | 🔍 emoji doesn't render in KOReader's font — KOReader uses custom fonts without emoji support. The TextWidget rendered as empty/invisible. | Replaced with `IconWidget` using built-in `appbar.search` SVG icon. |
| `attempt to index global 'input_dialog' (a nil value)` crash at line 645 | In LuaJIT, `local x = { callback = function() x:method() end }` — closures inside the table literal don't capture `x` as an upvalue because `x` hasn't been declared yet when the closure is created. The error said "global" not "upvalue", confirming Lua didn't see it as a local. Verified with isolated test: `local obj = { cb = function() print(obj) end }; obj.cb()` prints nil. | Split declaration: `local input_dialog; input_dialog = InputDialog:new{...}`. The variable exists (as nil) before the closures are created, so they capture it as an upvalue. By callback execution time, it's assigned. |
| Widget stub `new()` didn't call `init()` | KOReader's `FocusManager:extend` creates classes whose `new` calls `init()`. Our test stub's `new` returned a plain table, so `_refresh()` → `LibraryBrowserView:new{}` never called `_addBookList()`. Test for "search query passed to getItems" failed because `getItems` was never called. | Added `if obj.init then obj:init() end` to the class stub's `new` function. |
| Widget stubs missing `ges_events`/`key_events` | `LibraryBrowserView:init()` does `back_container.ges_events.TapBack = {...}` on InputContainer instances. Stub `new` returned plain tables without these fields → arithmetic on nil. | Widget stub's `new` now pre-populates `obj.ges_events = {}` and `obj.key_events = {}`. |
| Search query is set but results aren't filtered in emulator | **UNRESOLVED.** `browser.search("sanderson")` sets `_search_query` and calls `_view:_refresh()`, which creates a new view whose `_addBookList` calls `library_store.getItems({search="sanderson"})`. Debug log confirms query is set. But the emulator shows the same unfiltered list. Possible causes: (1) `_refresh()` timing — `UIManager:close(self)` + `UIManager:show(_view)` may be asynchronous, (2) `library_store` module loaded twice with separate state, (3) `getItems` search param not reaching `filter_items`. | Added debug `abs_logger.verbose` in `_addBookList` to trace. Needs further diagnosis. |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/library_browser.lua` | Added `IconWidget` import; replaced emoji search button with icon + query label; added `browser.search()`, `browser.getState()`, `browser._setSearchQuery()`, `browser._setCurrentPage()`; fixed closure scoping in `onSearch`; added debug logging in `_addBookList` |
| `spec/test_library_browser.lua` | **New file.** 5 tests: getState defaults, getState reflects manual set, search sets query + resets page, clear search, search integrates with library_store filter. Full KOReader widget stub suite. |

## Test Results

80 tests, 0 failures across 7 spec files:
- test_config: 12
- test_cover_cache: 7
- test_error_handler: 20
- test_library_browser: 5 (new)
- test_library_store: 20
- test_logger: 7
- test_manifest: 9

## Open Items & Next Steps

- [ ] **Diagnose why search results aren't filtered in the emulator** — `browser.search()` sets `_search_query` correctly and `_addBookList` passes it to `getItems({search=...})`, but the displayed list doesn't change. Check debug log output from emulator for `_addBookList: search=` lines. Investigate if `_refresh()` timing or module state is the issue.
- [ ] **Remove debug `abs_logger.verbose` in `_addBookList`** once search filtering is confirmed working.
- [ ] **Verify search indicator text** — the "Searching: ..." label below the header should appear when a query is active.
- [ ] **Test "Clear search" restores full list** in emulator.
- [ ] **Emulator visual test** for the magnifying glass icon rendering and tap target size.

---

*Log written by write-log skill*
