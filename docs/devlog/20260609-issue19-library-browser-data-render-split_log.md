# Library browser data/render split

> **Date:** 2026-06-09
> **Type:** issue
> **Reference:** [GitHub Issue #19](https://github.com/AlexKucera/absaudio.koplugin/issues/19)

## Goal

Split the library browser widget's data preparation from its rendering by extracting a `browser.prepare()` function from the monolithic `browser.show()`. Also eliminate the redundant `library_store.getItems()` call in `_addPageNav()`.

## What Was Done

- Extracted `browser.prepare()` from `browser.show()` — handles API config check, `getLibraries()`, `fetchAll()`, and cover cache init
- `browser.prepare()` returns `(data, nil)` on success where `data = { library_id }`, or `(nil, error_info)` on failure where `error_info = { type, message }`
- Refactored `browser.show()` to call `prepare()`, handle each error type with appropriate UI dialogs, then render the widget
- Eliminated redundant `getItems()` call in `_addPageNav()` — now reads `self._total_pages` set by `_addBookList()`
- Wrapped widget rendering in `pcall()` (only the render part, not data fetching) to handle KOReader widget runtime errors gracefully
- Removed debug `print()` statements from old `show()` implementation
- Added 5 new tests: 4 for `browser.prepare()` data paths + 1 source-code verification for `_addPageNav` de-duplication

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| `prepare()` returns structured error info `{type, message}` | Enables `show()` to handle each error type differently (config → silent back, api → "no libraries" dialog, network → "check connection" dialog) |
| `pcall` wraps only widget rendering, not data fetching | Old code wrapped everything in one pcall, hiding data errors. Now data errors are explicit and testable; pcall only catches widget creation failures (e.g., missing KOReader Screen dimensions in test env) |
| Source-code verification test for `_addPageNav` | Can't instantiate `LibraryBrowserView` in test env (needs KOReader widget runtime), so test reads source to verify `_addPageNav` doesn't call `getItems()` |
| Test mocks swap `package.loaded` and reload browser module | `has_api` and `api` are module-level locals set at require time, so we must reload the module to test different API configurations |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| Existing `show()` tests broke after refactor | Old `show()` wrapped everything in `pcall`, catching widget creation errors silently. New `show()` rendered outside pcall | Added `pcall` around only the widget rendering block, matching old behavior for test compat |
| `_addPageNav` called `getItems()` a second time | Original code called `library_store.getItems()` just to read `total_pages`, duplicating work already done in `_addBookList()` | Changed `_addPageNav` to read `self._total_pages` (set by `_addBookList`) instead |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/library_browser.lua` | Extracted `browser.prepare()`, refactored `show()` to call it, removed redundant `getItems` in `_addPageNav`, removed debug prints |
| `spec/test_library_browser.lua` | Added 5 new tests: 4 for `prepare()` data paths + 1 source-code verification for `_addPageNav` |

## Open Items & Next Steps

- [ ] Test `prepare()` on-device to verify cover cache init works correctly with the new code path
- [ ] Consider extracting `book_detail.prepare()` in a similar pattern for consistency (follows same data/render split pattern as issue #17 did for dashboard)

---

*Log written by write-log skill*
