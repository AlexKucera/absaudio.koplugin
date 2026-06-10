# Fix: Book detail resume progress always shows 0%

> **Date:** 2026-06-10
> **Type:** issue
> **Reference:** Bug report — resuming an audiobook download from the book detail view shows progress at 0 KB / X MB (0%), even though the file on disk correctly resumes (gets bigger, doesn't reset)

## Goal

Fix the download progress display when resuming a partial audiobook download initiated from the **book detail view** (`book_detail.lua`). The file on disk was correctly resuming via HTTP Range + append mode, but the progress widget always showed 0%.

## What Was Done

- **Diagnosed root cause** via code diff: The prior resume fix ([`fix-download-resume-resets-to-zero`](docs/devlog/20260610-fix-download-resume-resets-to-zero_log.md)) made three changes to `library_browser.lua:_onDownloadBook()`, but only one of those three was present in `book_detail.lua:_onDownloadBook()`:
  1. Skip `prepare_download` on resume ✅ (both files had it)
  2. `state.bytes_downloaded = already_on_disk` ❌ (**missing from book_detail**)
  3. `needed = total_sizes - already_on_disk` for free-space check ❌ (**missing from book_detail**)

- **Added `get_existing_bytes()` helper** to `book_detail.lua:912-921` — mirrors the identical helper in `library_browser.lua:662-671`. Sums `get_file_size()` for all `"partial"` status files in a manifest entry.

- **Added free-space check fix** (`book_detail.lua:931-946`) — calculates `needed = total_sizes - already_on_disk` so the free space check only verifies remaining bytes, not the full download size. Prevents false "insufficient disk space" on resume.

- **Added `state.bytes_downloaded = already_on_disk`** (`book_detail.lua:952`) — pre-seeds the download state with bytes already on disk, so `progress_fraction()` returns the correct value on resume.

- **Added 2 regression tests** (`spec/test_downloader.lua`):
  1. `resume: bytes_downloaded initialized to existing disk bytes` — proves correct behavior after fix
  2. `resume: progress at zero without pre-seeding (demonstrates the bug)` — documents the bug pattern

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Port exact same pattern from library_browser rather than extract shared module | The helper is ~8 lines and only used in two places; extraction would add indirection for minimal dedup. If a third caller appears, reconsider. |
| Write regression test in test_downloader.lua (not test_book_detail.lua) | The bug is about `create_download_state()` semantics — a downloader concern. book_detail is just the call site that forgot to initialize it. |
| Include both progress fix AND free-space fix | They stem from the same root cause (missing `already_on_disk` calculation). Leaving half fixed would be incomplete. |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| Progress shows "0 KB / X MB (0%)" on resume from book detail | `book_detail.lua` missing `state.bytes_downloaded = already_on_disk` line that `library_browser.lua` has | Added the line + the `get_existing_bytes()` helper it depends on |
| Free space check may falsely reject resume | `needed` was not reduced by `already_on_disk`, so it checked full size against free space | Changed to `needed = total_sizes - already_on_disk` |
| Prior fix log didn't flag book_detail as needing the same change | The prior session fixed library_browser first (primary path) and didn't audit book_detail for the same gap | This session caught it via user report + systematic diagnosis |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/book_detail.lua` | Added `get_existing_bytes()` helper (lines 912-921), free-space check with `already_on_disk` subtraction (lines 931-946), and `state.bytes_downloaded = already_on_disk` init (line 952) |
| `spec/test_downloader.lua` | Added 2 regression tests proving `bytes_downloaded` must be pre-seeded on resume |

## Open Items & Next Steps

- [ ] Verify on actual device/emulator that book detail → cancel → resume shows correct progress (e.g., "45.0 MB / 100.0 MB (45%)")
- [ ] Consider extracting `get_existing_bytes()` into `downloader.lua` if a third call site appears (dashboard or elsewhere)
- [ ] Prior open item still applies: verify ABS server supports Range requests for `/api/items/{id}/file/{ino}` endpoint (from [`fix-download-resume-resets-to-zero`](docs/devlog/20260610-fix-download-resume-resets-to-zero_log.md))

---

*Log written by write-log skill*
