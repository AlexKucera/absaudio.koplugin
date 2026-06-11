# Issue #26 — Remove Dead Download/Delete Code from Library Browser

> **Date:** 2026-06-11
> **Type:** issue
> **Reference:** [Issue #26](https://github.com/AlexKucera/absaudio.koplugin/issues/26)

## Goal

Remove ~406 lines of dead handler code from `library_browser.lua`. After PR #22 made `BookDetailView` fully self-contained (owning its `_onDownloadBook`, `_onDeleteBook`, `_onDeleteEbookOnly`, `_onOpenEbook` methods), the library browser still carried duplicate copies of these methods plus inline filesystem helpers that only existed to support them. The dashboard was cleaned in PR #22; this issue completes the same cleanup for library browser.

## What Was Done

### Dead Code Removal from `library_browser.lua`

**Removed methods (~400 lines):**
- `LibraryBrowserView:_onDownloadBook(item, ebook_only)` — full download pipeline with progress widget, pump loop, completion/cancel re-push handlers
- `LibraryBrowserView:_onDeleteBook(item, ebook_only)` — ConfirmBox + delete + refresh
- `LibraryBrowserView:_onDeleteEbookOnly(item)` — ebook-only file removal
- `LibraryBrowserView:_onOpenEbook(filepath)` — ReaderUI open

**Removed requires (only needed by dead methods):**
- `local ConfirmBox = require("ui/widget/confirmbox")`
- `has_manifest` / `manifest` pcall-require
- `has_config` / `config` pcall-require
- `downloader` pcall-require
- `has_progress` / `download_progress` pcall-require

**What was NOT changed:**
- `onBookTap()` — already clean from PR #22 (pushes `{ item = item }` only, no callbacks)
- All navigation, search, pagination, rendering code — untouched
- `book_detail.lua` — already self-contained, no changes needed

### Test Changes (`spec/test_library_browser.lua`)

| Old Test | New Test | Rationale |
|----------|----------|-----------|
| `onBookTap passes ebook_only flag through on_download` | `onBookTap pushes detail without download/delete callbacks` | Verifies no callbacks in onBookTap source |
| `re-push detail on_download callback unwraps ebook format` | `library_browser has no download/delete callback closures` | Source-level check for zero callback closures |
| *(none)* | `LibraryBrowserView does NOT have download/delete handlers` | Source-level check for absent method definitions |
| *(none)* | `library_browser does not require downloader or download_progress` | Source-level check for absent module requires |

## Acceptance Criteria Status

| # | Criteria | Status |
|---|----------|--------|
| 1 | Remove `_onDownloadBook`, `_onDeleteBook`, `_onDeleteEbookOnly`, `_onOpenEbook` from library_browser.lua | ✅ Done |
| 2 | Remove `downloader` and `download_progress` requires from library_browser.lua | ✅ Done |
| 3 | Simplify completion/cancel re-push callbacks to bare nav.pop/push | ✅ Done (removed entirely — lived inside deleted methods) |
| 4 | All existing tests pass (702+ test_library_browser tests included) | ✅ 17/17 library_browser, 330 total pass |
| 5 | No regressions in test_book_detail or test_dashboard_widget | ✅ 29/29 book_detail, 22/22 dashboard pass |

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Use source-level regex tests instead of runtime instance checks | Mock environment can't fully instantiate LibraryBrowserView (missing ffi/blitbuffer etc.), so runtime `view._onDownloadBook == nil` tests pass vacuously. Source-level pattern matching is more reliable |
| Remove ConfirmBox/manifest/config requires too | Grepping confirmed all references were exclusively within the dead method block — no other code in library_browser uses them |
| Replace 2 old tests rather than just delete them | The old tests checked for presence of callback patterns that are now correctly absent; new tests assert the clean state we want |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| First version of "does NOT have handlers" test passed vacuously | `browser.show({}`) returns nil view in mock env (missing UI deps), so `if not view then return end` exited before any assertions | Switched to source-level pattern matching (`source:match("function LibraryBrowserView:_onDownloadBook")`) |
| `mock.assert_not_equals` doesn't exist | Only `mock.assert_equals` is defined in test_helper.lua | Changed to `mock.assert_equals(val ~= nil, true, msg)` |
| Test 14 "onBookTap passes ebook_only" used synthetic callback not from actual code | Pre-PR#22 test created its own closure to test unwrapping pattern; after cleanup there's no real callback to test | Replaced with source-level check that onBookTap body contains no `on_download=` assignments |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/library_browser.lua` | **−406 net lines** (1243 → 842). Removed 4 dead methods, 5 unused requires, inline fs helpers |
| `spec/test_library_browser.lua` | Replaced 2 obsolete callback-pattern tests with 4 new negative/assertion tests (+2 net tests, 15 → 17) |

## Metrics

| Metric | Before | After | Delta |
|--------|--------|-------|-------|
| library_browser.lua lines | 1243 | 842 | **−401** |
| test_library_browser tests | 15 | 17 | **+2** |
| Total test suite | 328 pass | 330 pass | **+2** |
| GitNexus nodes | 571 | 608 | +37 (re-indexed) |

## Next Steps

None — this completes the PR #22 follow-up cleanup. Both dashboard_widget (cleaned in PR #22) and library_browser (this issue) now pass data-only to BookDetailView, which owns all action behavior.
