# Fix: Ebook download was a stub that never executed

> **Date:** 2026-06-10
> **Type:** issue
> **Reference:** User-reported bug — tapping ebook download button shows "Ebook download prepared" but nothing downloads

## Goal

Fix ebook downloads so that tapping the ebook download button in BookDetailView actually downloads the ebook file to disk, the same way the audio download pipeline works.

## What Was Done

- **Identified root cause:** In `library_browser.lua:_onDownloadBook()`, the ebook branch called `downloader.prepare_ebook_download()` to create a manifest entry, then showed an InfoMessage "Ebook download prepared" and **returned immediately** — never reaching the shared download execution pipeline. There was a `TODO` comment acknowledging the stub.
- **Unified the ebook and audio paths:** Restructured `_onDownloadBook` so both ebook and audio branches set a shared `result` variable, then fall through to the same download pipeline (free space check → progress widget → chunked download → manifest update).
- **Removed the dead-code stub:** Deleted the `TODO` comment, the "Ebook download prepared" InfoMessage, and the early `return` that prevented the download from executing.
- **Verified all tests pass:** 282 tests pass across all spec files (77 downloader, 14 library_browser, etc.). Pre-existing manifest test failures are unrelated.

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Unified ebook + audio into shared pipeline | The download pipeline (free space check, progress widget, chunked HTTP, manifest update) is identical for both file types. Duplicating it would be worse than sharing. |
| Kept `prepare_ebook_download` separate from `prepare_download` | Ebook preparation has different file discovery logic (`media.ebookFile` vs `media.audioFiles`) and manifest entry shape (no duration/chapters). The *preparation* differs but *execution* is the same. |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| Ebook download button shows "prepared" but nothing downloads | `_onDownloadBook` had a `TODO` stub that returned early after `prepare_ebook_download` — the download execution code was never reached | Removed the early return; let the ebook `result` flow into the shared download pipeline |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/library_browser.lua` | Restructured `_onDownloadBook` to unify ebook and audio paths into a shared download pipeline; removed TODO stub |

## Open Items & Next Steps

- [ ] Manual testing on device/emulator to verify ebook files actually download to disk
- [ ] Verify ebook download works for books with `media.ebookFile` (single ebook) and `media.ebooks` (multiple ebooks)
- [ ] Verify ebook download progress UI displays correctly (progress bar, file count)
- [ ] Verify ebook resume works (cancel mid-download, tap download again)
- [ ] Pre-existing `test_manifest.lua` failures (2 tests) need separate fix

---

*Log written by write-log skill*
