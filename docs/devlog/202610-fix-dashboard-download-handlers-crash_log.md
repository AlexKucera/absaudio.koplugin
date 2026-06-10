# Fix Dashboard Download Handlers — PR Review: Non-existent Function + Emulator Crash

> **Date:** 2026-06-10
> **Type:** generic
> **Reference:** PR review comment — `downloader.download_single_file` does not exist

## Goal

Fix two bugs identified in a PR review of `absaudio/dashboard_widget.lua`:

1. **Non-existent function call**: `downloader.download_single_file(file, entry, deps)` — this function doesn't exist in `downloader.lua`. The real API uses `start_chunked_download(entry, file, deps)`.
2. **Wrong argument order**: Dashboard passed `(file, entry, deps)` but the real API expects `(entry, file, deps)`.

Additionally, ensure the book detail view has **identical functionality** regardless of navigation path (dashboard → detail vs library browser → detail).

## What Was Done

### 1. TDD: Wrote failing tests first (RED)

Added 3 new tests to `spec/test_dashboard_widget.lua`:

- **`_onBookTap passes correct action callbacks from dashboard`** — verifies `on_download`, `on_delete`, `on_open_ebook` are functions passed to detail view
- **`DashboardView has _onDownloadBook/_onDeleteBook/_onOpenEbook using correct API`** — verifies methods exist AND source code scan confirms no calls to non-existent `download_single_file`
- Updated existing test `_onBookTap enriches item data without action callbacks` to assert callbacks ARE present (was incorrectly asserting nil after initial overcorrection)

### 2. Restored requires and callback wiring in dashboard_widget.lua

- Added back `has_downloader/downloader`, `has_abs_config/abs_config`, `has_progress/progress`, `has_cover_cache/cover_cache` requires
- Restored callback wiring in `_onBookTap` with proper unwrapping closures matching `library_browser` pattern:
  ```lua
  on_download = function(data)
      local book_item = data.item or data
      local ebook_only = data.ebook_only or false
      self:_onDownloadBook(book_item, ebook_only)
  end,
  ```

### 3. Rewrote `_onDownloadBook` handler (~150 lines)

Full download pipeline mirroring `library_browser:_onDownloadBook`:

- Ebook vs audio path branching (`ebook_only` flag)
- Resume detection via `manifest.hasIncompleteFiles()` — skips `prepare_download` for partials
- Free space check via `downloader.check_free_space()`
- Progress widget integration (`download_progress.show`)
- File-by-file coroutine loop using **correct API**: `downloader.start_chunked_download(entry, file, deps)`
- Completion/cancellation → refresh detail view via `nav.pop()` + `nav.push('detail', ...)`
- Uses `scheduleIn(0.05, ...)` not `scheduleIn(0, ...)` per project learnings (event loop starvation)

### 4. Rewrote `_onDeleteBook` handler (~40 lines)

- Confirmation dialog via `ConfirmBox:new`
- `downloader.delete_book(item.id, manifest, fs)` for actual deletion
- Refreshes detail view after delete

### 5. Added `_onDeleteEbookOnly` helper

- Iterates manifest entry files, removes ebook-type files from disk
- Clears status tracking, flushes manifest
- Refreshes detail view

### 6. Rewrote `_onOpenEbook` handler

- Simple delegation to `ReaderUI:showReader(filepath)`

### 7. Fixed variable shadowing bug (crash #1)

**Problem:** Line 52 declared `local has_config, config = pcall(require, "absaudio/config")` which **shadowed** KOReader's built-in `config` module (loaded at line 35 as `local config = require("config")`). Downstream code including font initialization got an absaudio config object or error string instead.

**Fix:** Renamed to `local has_abs_config, abs_config = pcall(require, "absaudio/config")`. All references inside handlers updated to use `abs_config.get(...)`.

### 8. Fixed missing cover_cache require + TextWidget face crash (crash #2)

**Two-part bug:**

1. `has_cover_cache` and `cover_cache` were used in `_buildBookRow()` but never declared via `pcall(require, ...)`. Always nil → cover cache branch never taken → always fell through to placeholder.
2. Placeholder `TextWidget:new{ text = "🎵" }` had **no `face` parameter**. KOReader's `font.lua:386` crashed with `attempt to index local 'face' (a nil value)` during widget paint.

**Fix:**
- Added `local has_cover_cache, cover_cache = pcall(require, "absaudio/cover_cache")` to requires
- Added proper face to placeholder: `face = Font:getFace("cfont", Screen:scaleBySize(22))` matching library_browser pattern

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Detail view must have identical buttons from any navigation path | User explicitly corrected initial overcorrection where callbacks were removed. Dashboard→detail must show same Download/Resume/Delete/Open Ebook buttons as Library→detail |
| Mirror library_browser handler implementations exactly | Same pipeline logic (prepare → resume check → space check → progress → chunked loop → refresh). Reduces divergence risk and makes both paths auditable side-by-side |
| Use `abs_config` name to avoid shadowing KOReader's `config` | Lua local scoping means `local config` at line 52 shadows line 35's `config` for the entire rest of the file. Renaming is safer than reordering requires |
| `scheduleIn(0.05)` not `scheduleIn(0)` for pump loop | Per project AGENTS.md learnings: `scheduleIn(0)` starves UIManager event loop by making tasks "due now" |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| **Unbalanced parentheses in test file** | Edit replacing `mock.assert_equals` block left one `)` missing on line 644 (`"on_open_ebook should be nil..."` had no closing paren) | Added missing `)` |
| **Emulator crash: `attempt to index local 'face' (a nil value)` at font.lua:386** | Two causes: (1) `has_cover_cache` never declared → always hit placeholder; (2) placeholder `TextWidget` missing `face` param | Added cover_cache require; added `face = Font:getFace("cfont", Screen:scaleBySize(22))` to placeholder |
| **Variable shadowing causing potential downstream corruption** | `local has_config, config = pcall(...)` shadowed KOReader's `config` from line 35 | Renamed to `abs_config` |
| **Brace mismatch after edit** | Manual edit of placeholder block broke `{...}` nesting structure | Replaced entire else-block with correct structure |
| **Initial overcorrection: removed all dashboard action callbacks** | Misinterpreted PR review as "dashboard shouldn't have downloads" rather than "fix the broken implementation" | User corrected: restored full callback wiring with correct API |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/dashboard_widget.lua` | Added `downloader`, `abs_config`, `progress`, `cover_cache` requires; restored callback wiring in `_onBookTap`; rewrote `_onDownloadBook` (correct API: `start_chunked_download`), `_onDeleteBook`, `_onDeleteEbookOnly`, `_onOpenEbook`; fixed TextWidget placeholder face; renamed `config` → `abs_config` to prevent shadowing |
| `spec/test_dashboard_widget.lua` | Updated existing test to assert callbacks present (not nil); added 2 new tests: callback presence verification + source-level API correctness scan (no `download_single_file` calls); total: 22 dashboard tests |

## Test Results

```
320 pass, 0 fail (full suite)
  test_api.lua:          26 passed
  test_book_detail.lua:   24 passed
  test_chunked_http.lua:   6 passed
  test_config.lua:        12 passed
  test_cover_cache.lua:    7 passed
  test_dashboard_widget.lua: 22 passed  (+2 new)
  test_downloader.lua:    80 passed
  test_error_handler.lua: 20 passed
  test_library_browser.lua: 15 passed
  test_library_store.lua: 25 passed
  test_logger.lua:         7 passed
  test_main.lua:          11 passed
  test_manifest.lua:       20 passed
  test_navigator.lua:      12 passed
  test_widget_helpers.lua: 31 passed
```

## Open Items & Next Steps

- [ ] Verify dashboard renders correctly in emulator after all fixes (user testing)
- [ ] Consider extracting shared download/delete/ebook handler logic into a helper module to eliminate duplication between `library_browser.lua` and `dashboard_widget.lua` (both now have near-identical ~250 lines of handler code)
- [ ] Run `gitnexus analyze` to update knowledge graph index (done mid-session but may need refresh after final changes)

---

*Log written by write-log skill*
