# Issue #5: Download Pipeline — TDD + UI Wiring

> **Date:** 2026-06-09
> **Type:** issue
> **Reference:** [GitHub Issue #5](https://github.com/AlexKucera/absaudio.koplugin/issues/5)

## Goal

Implement the complete download pipeline for the absaudio.koplugin: a download orchestrator module with filename sanitization, format preference filtering, file selection, free space checking, resume via HTTP Range, cancel mechanism, delete book, ebook download, and startup reconciliation. Then wire the download/delete/resume buttons into BookDetailView via LibraryBrowserView.

## What Was Done

### New module: `absaudio/downloader.lua` (~396 lines)

Created via strict TDD (11 vertical slices, red→green for each):

1. **`sanitize_filename(filename)`** — Replaces `: < > | " ? * \ /` with `_`, strips leading/trailing spaces and dots, returns `"untitled"` if empty. 10 tests.
2. **`filter_audio_files(files, preferred_format)`** — Filters by preferred format with fallback chain: preferred → mp3 → all. 6 tests.
3. **`select_files_to_download(files)`** — Returns files with `pending` or `partial` status (skips `complete`). 5 tests.
4. **`calculate_download_size(files)`** — Sums sizes of pending/partial files. `check_free_space(needed, available)` — comparison. 6 tests.
5. **`prepare_download(item, manifest, config)`** — Validates item, extracts audioFiles from expanded ABS item, filters by preferred format, creates manifest entry with all files as `pending`. Returns errors for `already_downloaded` and `no_audio_files`. 4 tests.
6. **`build_range_header(file, local_size)`** — Returns `"bytes=N-"` for partial files where local_size < expected size. `build_download_request(item_id, file, local_path, token, local_size, server_url)` — Constructs HTTP request table with Range header when resuming. 6 tests.
7. **`create_download_state()`** — Returns state object with `cancelled`, `current_file`, `total_files`, `bytes_downloaded`, `total_bytes`, and methods `cancel()`, `is_cancelled()`, `progress_fraction()`. 4 tests.
8. **`delete_book(abs_item_id, manifest, fs)`** — Deletes all files via `fs.delete_file()`, removes directory via `fs.delete_dir()`, removes manifest entry. Returns false for unknown books. 3 tests.
9. **`get_ebook_files(item)`** + **`prepare_ebook_download(item, manifest, config)`** — Extracts ebooks from ABS item, creates manifest entry with `type = "ebook"`. 4 tests.
10. **`reconcile_manifest(manifest, fs)`** — Scans all books, flags `complete` files whose actual disk size doesn't match expected size as `partial`. 4 tests.

### New test file: `spec/test_downloader.lua` (52 tests)

### Modified: `manifest.lua` — Added 5 query helper functions

- `manifest.isDownloaded(abs_item_id)` — true when all files are `complete`
- `manifest.hasIncompleteFiles(abs_item_id)` — true when any file is `pending` or `partial`
- `manifest.getIncompleteFiles(abs_item_id)` — returns array of pending/partial files
- `manifest.getTotalFileSize(abs_item_id)` — sum of all file sizes
- `manifest.getDownloadedSize(abs_item_id)` — sum of complete file sizes

### Modified: `spec/test_manifest.lua` — Added 8 tests for new helpers

### Modified: `absaudio/book_detail.lua` — Rewrote `_addDownloadStatus()` with 3 states

- **State 1: All complete** → "✓ Downloaded" badge + "🗑 Delete" button
- **State 2: Incomplete** → "⚠ Incomplete download" badge + "⬇ Resume" button + "🗑 Delete" button
- **State 3: Not in manifest** → "Not downloaded" + "⬇ Download" button
- Added `on_delete` callback wiring through `detail.show()` → `_renderView()`
- Updated mock manifest in tests to include `isDownloaded` and `hasIncompleteFiles`
- Added 3 new tests for download status states

### Modified: `absaudio/library_browser.lua` — Wired download/delete handlers

- Added `require("manifest")`, `require("config")`, `require("absaudio/downloader")` at module level
- `onBookTap()` now passes `on_download` and `on_delete` callbacks to `nav.push("detail", ...)`
- Added `_onDownloadBook(item)` — calls `downloader.prepare_download()`, shows InfoMessage with result
- Added `_onDeleteBook(item)` — calls `downloader.delete_book()`, shows InfoMessage with result
- Updated `onBookTap` test to verify callbacks are passed

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Downloader is a pure-logic module with injected dependencies | `manifest` and `config` are passed as parameters, not required internally. This makes all downloader functions testable without KOReader framework. Tests pass mock objects. |
| Manifest helpers added to manifest.lua, not downloader | `isDownloaded`, `hasIncompleteFiles` query manifest state — they belong in the manifest module. Downloader consumes them. |
| All manifest function calls use dot syntax (`manifest.getBook(id)`) not colon (`manifest:getBook(id)`) | Manifest functions are module-level functions that access module-level `settings`, not `self`. Colon syntax silently passes the module table as first arg, causing `nil` key crashes at runtime. Tests used `_` to absorb the spurious arg, masking the bug. |
| Top-level `require()` for downloader in library_browser (no `pcall`) | KOReader's plugin loader may not resolve all paths the same way as standalone luajit. Using plain `require` matches the pattern of every other sub-module in this plugin (`library_store`, `cover_cache`). If the require fails, the whole module fails to load — same behavior as all other modules. |
| `_onDownloadBook` currently only calls `prepare_download` — no actual HTTP transfer | The coroutine-based chunked download loop (ADR 0005) is not yet implemented. `prepare_download` creates the manifest entry and file list, but the actual `api.downloadFile` calls + progress widget are a separate piece. |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| `attempt to index global 'downloader' (a nil value)` in emulator | `library_browser.lua` used `pcall(require, "absaudio/downloader")` inside handler functions. `pcall` returned `(true, nil)` in KOReader's plugin environment — the module loaded but the reference was nil because the `local has_dl, downloader = pcall(require, ...)` assignment captured the module in `has_dl` (boolean true) and `downloader` was nil. | Changed to top-level `local downloader = require("absaudio/downloader")` — same pattern as all other sub-modules. |
| `attempt to index local 'manifest' (a nil value)` in emulator | `library_browser.lua` never required `manifest` or `config` — the download handler referenced them as nil globals. | Added `local has_manifest, manifest = pcall(require, "manifest")` and `local has_config, config = pcall(require, "config")` at module level. |
| `table index is nil` in `manifest.addBook` at runtime | `downloader.lua` called manifest functions with colon syntax: `manifest:addBook(entry)`. This expands to `manifest.addBook(manifest, entry)` — the function receives the module table as first arg, and `entry.abs_item_id` becomes nil because the entry is in the second positional arg which the function ignores. | Changed all 7 manifest calls from colon (`:`) to dot (`.`) syntax. Also fixed all test mocks to use `function(id)` instead of `function(_, id)`. |
| Download button not appearing in BookDetailView | `library_browser.lua:onBookTap()` called `nav.push("detail", { item = item })` without passing `on_download` callback. `_addDownloadStatus()` only renders the Download button when `self.on_download` is truthy. | Added `on_download` and `on_delete` callbacks to the `nav.push` data in `onBookTap`. |
| "✓ Downloaded" shown for partial downloads | Old `_addDownloadStatus()` checked `manifest.getBook(id)` — if any manifest entry exists (even with partial files), it showed "✓ Downloaded". | Rewrote to use `manifest.isDownloaded()` and `manifest.hasIncompleteFiles()` for proper 3-state logic. |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/downloader.lua` | **NEW** — Download orchestrator module (52 tests): sanitize_filename, filter_audio_files, select_files_to_download, calculate_download_size, check_free_space, prepare_download, build_range_header, build_download_request, create_download_state, delete_book, get_ebook_files, prepare_ebook_download, reconcile_manifest |
| `spec/test_downloader.lua` | **NEW** — 52 tests across 11 TDD slices |
| `manifest.lua` | Added 5 query helpers: isDownloaded, hasIncompleteFiles, getIncompleteFiles, getTotalFileSize, getDownloadedSize |
| `spec/test_manifest.lua` | Added 8 tests for new manifest helpers |
| `absaudio/book_detail.lua` | Rewrote `_addDownloadStatus()` with 3-state logic (downloaded/incomplete/not downloaded); added `on_delete` callback wiring; added 3 tests |
| `absaudio/library_browser.lua` | Added requires for manifest/config/downloader; wired `on_download` + `on_delete` callbacks in `onBookTap`; added `_onDownloadBook` + `_onDeleteBook` handlers |
| `spec/test_library_browser.lua` | Updated `onBookTap` test to verify `on_download`/`on_delete` callbacks are passed |

## Open Items & Next Steps

- [ ] **Actual file download execution** — `_onDownloadBook` currently only calls `prepare_download` (creates manifest entry). Need to implement the coroutine-based chunked download loop that calls `api.downloadFile` for each pending/partial file, writes to disk, updates manifest status per-file. This is the core of ADR 0005.
- [ ] **Progress widget** — `download_progress.lua` modal showing current file/total, bytes/total, %, ETA, cancel button. `create_download_state()` already tracks all metrics.
- [ ] **Cancel button wiring** — `state:cancel()` exists but needs to be connected to a UI button that the progress widget provides.
- [ ] **Re-download prompt** — `prepare_download` returns `"already_downloaded"` but the UI should show a confirmation dialog ("Already downloaded. Re-download?") instead of a flat refusal.
- [ ] **Startup scan wiring** — `reconcile_manifest()` exists but is not called from `main.lua` on plugin startup. Need to wire it.
- [ ] **Ebook download button** — `prepare_ebook_download` + `get_ebook_files` exist but no UI button in book_detail for ebooks.
- [ ] **Integration test in emulator** — Full download flow against real ABS server (browse → download → verify files → delete → verify cleanup).
- [ ] **Free space check before download** — `check_free_space` exists but is not called from `_onDownloadBook`.
- [ ] **Delete confirmation dialog** — `_onDeleteBook` should show "Delete this book?" confirmation before removing files.
- [ ] **Download dir setting** — `config.get("download_dir")` defaults to `/tmp/audiobooks`. Need a settings UI to configure this.

---

*Log written by write-log skill*
