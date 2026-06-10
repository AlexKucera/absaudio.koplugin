# PR #22 Review Findings — Self-Contained Book Detail View

> **Date:** 2026-06-10
> **Type:** issue
> **Reference:** [PR #22](https://github.com/AlexKucera/absaudio.koplugin/pull/22) (Greptile review comments)

## Goal

Audit and fix all open review findings on PR #22. The Greptile review identified 4 bugs in the dashboard→detail download path, all stemming from a fundamental architectural flaw: **`book_detail.lua` was a passive view that received behavior via callbacks from whoever pushed it**, causing ~160 lines of duplicated handler code between `library_browser` (working) and `dashboard_widget` (broken).

The fix: make `BookDetailView` own its download/delete/ebook-open behavior as instance methods, so callers pass only data (`item`), not behavior.

## What Was Done

### Architecture Refactor: Passive View → Self-Contained Widget

- **Moved 4 action methods into `BookDetailView`** (`absaudio/book_detail.lua`):
  - `_onDownloadBook(item, ebook_only)` — full pipeline: prepare → free space check → progress widget → `start_chunked_download` → pump loop (`scheduleIn(0.05)`) → finalize → refresh detail via `nav.pop()`/`nav.push("detail", {item})`
  - `_onDeleteBook(item, ebook_only)` — ConfirmBox → `downloader.delete_book()` → InfoMessage → refresh
  - `_onDeleteEbookOnly(item)` — manifest ebook file removal → flush → InfoMessage → refresh
  - `_onOpenEbook(filepath)` — `ReaderUI:showReader(filepath)`
- **Wired all tap handlers** to call `self.detail_ref:_onXxx(...)` instead of external callback closures
- **Added requires** for `ConfirmBox`, `downloader`, `abs_config`, `download_progress`, `chunked_http`, `lfs`

### Bug Fixes (All 4 PR #22 Findings)

| # | Finding | Fix |
|---|---------|-----|
| 1 | Dashboard `_onDownloadBook` discarded coroutine handle (no bytes transferred) | Eliminated — single working implementation now lives in `book_detail:_onDownloadBook()` |
| 2 | `self_ref` nil crash in dashboard delete handlers (`self_ref` was local to `_onDownloadBook` only) | Eliminated — methods use `self` directly; dead dashboard copies removed |
| 3 | `ConfirmBox` never required (crashed re-download + delete-confirm) | Added `local ConfirmBox = require("ui/widget/confirmbox")` to book_detail imports |
| 4 | `config:get` colon-call in `downloader.lua` silently ignored user settings (3 sites) | Changed all 3 to `config.get` dot-call in `prepare_download` and `prepare_ebook_download` |

### Caller Cleanup

- **`dashboard_widget.lua`**: Removed ~278 lines of dead handler code (`_onDownloadBook`, `_onDeleteBook`, `_onDeleteEbookOnly`, `_onOpenEbook`). `_onBookTap` now pushes `{ item = detail_item }` without callbacks. Added missing `onClose()` method.
- **`library_browser.lua`**: Stripped callback parameters from 5 `nav.push("detail", ...)` call sites. Each went from ~12 lines to 2 lines.

### Tests Added (+4 new, several updated)

| Test | What it verifies |
|------|-----------------|
| `_onDownloadBook calls start_chunked_download and schedules pump` | Method exists, calls downloader, schedules pump loop |
| `_onDeleteBook shows ConfirmBox and deletes book` | Method exists, shows ConfirmBox, calls `delete_book` |
| `_onOpenEbook opens ReaderUI with filepath` | Method exists, invokes ReaderUI with correct path |
| `detail.show without callbacks still has working action methods` | New interface works without old callback parameters |
| `_onBookTap pushes detail with item but no callbacks` | Dashboard regression: no callbacks leaked into nav.push |
| `DashboardView does NOT have download/delete handlers` | Negative test: handlers removed from dashboard |

**Final count: 322 tests pass** (was 326 before refactor; net -4 after removing dead-code tests that checked for now-absent dashboard handlers, +4 new self-containment tests, +2 updated tests)

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Move behavior INTO book_detail rather than share via module | Every new entry point (search, history, recommendations) would have had to re-implement ~160 lines of handlers. Single source of truth eliminates this forever |
| Keep callback params in `detail.show()` signature as optional/no-op | Backward compat during transition; callers can pass them but they're ignored since tap handlers use `self.detail_ref:` methods directly |
| Use `scheduleIn(0.05, pump)` not `scheduleIn(0, pump)` | From prior session learning: `scheduleIn(0)` starves UIManager event loop by making tasks "due now" in the drain loop |
| Remove dashboard handler methods entirely vs stub them | Dead code is maintenance burden. If someone adds download UI to dashboard later, it goes through book_detail which already owns the logic |
| Add `onClose()` to DashboardView (was missing) | Pre-existing bug exposed by test cleanup — `_onOpenSettings` called `self:onClose()` which didn't exist |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| Missing `end` for `DashboardView:onClose()` block swallowed ~80 lines of code into the function body | Manual edit added `onClose` method but forgot closing `end` before next method definition | Added missing `end`, removed extra dangling `end` at EOF |
| Subagent acceptance reports failed JSON parsing | Acceptance schema validation rejected evidence arrays with string values like `"commands-run"` instead of enum values | Not a code issue — tooling friction; verified results directly with `lua spec/` commands instead |
| npm ENOTEMPTY error crashed worker subagent | Race condition in npm install during parallel subagent execution | Retried work directly; subagent had already completed edits before npm crash |
| Dashboard tests expected callbacks in pushed data (19 failures after removing callback wiring) | Tests were written against old interface where `_onBookTap` passed `on_download/on_delete/on_open_ebook` | Updated 4 test assertions to verify `nil` for each callback field (new contract) |
| `luac -p` caught structural syntax error that `require` didn't show clearly | Missing `end` caused parse error at EOF but runtime error was opaque ("attempt to call a nil value (field 'show')") | Used `luac -p` for fast syntax checking after each edit |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/book_detail.lua` | +560/-~200 net: Added 4 action methods (~280 lines), wired tap handlers to self methods, added 6 requires (ConfirmBox, downloader, abs_config, progress, chunked_http, lfs) |
| `absaudio/dashboard_widget.lua` | +16/-292 net: Removed 4 dead handler methods (~278 lines), simplified `_onBookTap` to push item-only, added `onClose()` method |
| `absaudio/downloader.lua` | +3/-3: Fixed 3 `config:get` → `config.get` colon-calls in prepare_download (×2) and prepare_ebook_download (×1) |
| `absaudio/library_browser.lua` | +0/-14: Stripped callback parameters from 5 `nav.push("detail", ...)` call sites |
| `spec/test_book_detail.lua` | +120/-~60 net: Added 4 new self-containment tests with pre-load mocks for downloader/progress/config/ConfirmBox |
| `spec/test_dashboard_widget.lua` | +20/-~35 net: Updated 4 existing tests for new no-callbacks contract, added 1 regression test, replaced handler-existence test with negative test |

## Open Items & Next Steps

- [ ] Run `gitnexus analyze` to update knowledge graph with new method ownership
- [ ] Run `gitnexus_detect_changes()` before committing to verify change scope
- [ ] Consider whether library_browser's now-dead `_onDownloadBook`/`_onDeleteBook`/`_onDeleteEbookOnly`/`_onOpenEbook` methods should be removed (they may still be referenced internally — verify with grep)
- [ ] User testing: navigate to book detail from dashboard, tap Download/Delete/Open Ebook — all should work identically to library browser path
- [ ] Update CHANGELOG.md with this refactor

---

*Log written by write-log skill*
