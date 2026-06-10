# Fix: Download resume always starts from zero

> **Date:** 2026-06-10
> **Type:** issue
> **Reference:** Bug report — resuming a cancelled download restarts from 0 KB instead of continuing

## Goal

Fix the download resume flow so that when a user cancels an in-progress download and clicks Resume, the download picks up where it left off (using HTTP Range headers and append mode) instead of starting from zero.

## What Was Done

- **Diagnosed root cause**: `_onDownloadBook` in `library_browser.lua` always called `downloader.prepare_download()`, even for resumes. `prepare_download` creates a fresh manifest entry with all files set to `status = "pending"`, overwriting the existing entry that had `status = "partial"` from the cancelled download. The resume logic in `start_chunked_download` checks `file.status == "partial"` to decide whether to use append mode and send a `Range` header — but it never fired because status was always reset to `"pending"`.

- **Added resume detection** in `_onDownloadBook` (`library_browser.lua:638-672`): Before calling `prepare_download`, check `manifest.getBook(item.id)` and `manifest.hasIncompleteFiles(item.id)`. If the book exists in the manifest with incomplete files, skip `prepare_download` and use the existing manifest entry directly, preserving "partial" statuses.

- **Fixed progress display** (`library_browser.lua:673-713`): Added `get_existing_bytes()` helper to calculate bytes already on disk from partial files. Initialized `state.bytes_downloaded` to `already_on_disk` so the progress widget shows the true resume position (e.g., "45.0 MB / 100.0 MB (45%)") instead of "0.0 KB / 100.0 MB (0%)".

- **Fixed free space check** (`library_browser.lua:694`): Changed `needed` to `total_sizes - already_on_disk` so the free space check only verifies space for the remaining bytes, not the full download.

- **Added diagnostic logging** in `start_chunked_download` (`downloader.lua:586-593`): Logs file status, local size, and whether resume mode was activated, to aid future debugging.

- **Added 4 regression tests** (`spec/test_downloader.lua`):
  1. `prepare_download resets partial files to pending (resume bug)` — proves `prepare_download` destroys partial status
  2. `start_chunked_download opens 'wb' when status is pending` — proves pending → overwrite mode, no Range header
  3. `start_chunked_download resumes with 'ab' when status is partial` — proves partial → append mode + Range header
  4. `E2E resume: cancel then resume preserves partial status` — full cancel→resume flow simulation

- **Total tests**: 77 downloader tests pass (up from 73), all other test suites unchanged.

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Skip `prepare_download` entirely for resume instead of modifying it | `prepare_download`'s job is to create a fresh manifest entry from API data. Modifying it to handle the resume case would mix two concerns. Checking before calling it is cleaner — the existing entry already has everything needed. |
| Use `manifest.hasIncompleteFiles()` for detection | Already exists and checks for both "pending" and "partial" statuses. Matches the semantics of "this download was started but not completed". |
| Calculate `already_on_disk` inline rather than adding to downloader module | Simple helper, only needed in `_onDownloadBook`. Keeps downloader focused on download mechanics. |
| Only count `"partial"` files for `already_on_disk`, not `"pending"` | `"pending"` files have never had bytes written to disk. Only `"partial"` files (cancelled mid-download) have actual data on disk. |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| `prepare_download` resets file statuses to "pending" | `prepare_download` always builds a new manifest entry with `status = "pending"` and `manifest.addBook()` blindly overwrites the existing entry | Skip `prepare_download` when resuming; use existing manifest entry with "partial" statuses intact |
| Progress display shows "0 KB" on resume | `state.bytes_downloaded` was initialized to 0 regardless of existing partial file data on disk | Calculate `already_on_disk` from partial file sizes and initialize `state.bytes_downloaded = already_on_disk` |
| Free space check double-counts on resume | `needed` was set to total file sizes, not remaining bytes | Changed to `needed = total_sizes - already_on_disk` |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/library_browser.lua` | Added resume detection before `prepare_download`; added `get_existing_bytes()` helper; fixed progress init and free space check |
| `absaudio/downloader.lua` | Added diagnostic logging in `start_chunked_download` for resume decision |
| `spec/test_downloader.lua` | Added 4 tests: 3 regression + 1 E2E resume flow |

## Open Items & Next Steps

- [ ] Verify on actual device/emulator that ABS server supports Range requests for `/api/items/{id}/file/{ino}` endpoint
- [ ] If ABS returns 200 (full file) instead of 206 (partial) when Range header is sent, `chunked_http.download` will append the full file to the existing partial file, corrupting it. May need to detect this case and fall back to overwrite.
- [ ] Remove diagnostic logging in `start_chunked_download` once resume is confirmed working on device

---

*Log written by write-log skill*
