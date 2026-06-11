# Fix: Crash on ebook re-download after cancel (nil `id` field)

> **Date:** 2026-06-10
> **Type:** issue
> **Reference:** Crash in emulator — download ebook → cancel → tap download again

## Goal

Fix the crash `attempt to concatenate field 'id' (a nil value)` at `library_browser.lua:613` that occurs when downloading an ebook, cancelling the download, and then tapping the download button again.

## What Was Done

- Diagnosed the root cause: three re-push sites in `_onDownloadBook` passed raw callback data to `_onDownloadBook` without unwrapping the `{ item=..., ebook_only=true }` envelope that the ebook button uses
- Applied the same unwrapping pattern (`data.item or data` / `data.ebook_only or false`) to all three re-push callbacks in `library_browser.lua`
- Added a source-level regression test that asserts no `on_download` callback passes raw `b` to `_onDownloadBook` and all use the unwrapping pattern

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Source-level regex test instead of integration test | The bug is a callback contract mismatch across 4 call sites — a source scan ensures no future re-push site regresses. An integration test would require mocking the entire download/cancel/re-push pipeline. |
| Consistent unwrapping pattern across all 4 sites | The initial `onBookTap` already had this pattern. Duplicating it at all re-push sites ensures the ebook button's `{ item, ebook_only }` envelope is always unwrapped regardless of entry path. |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| `attempt to concatenate field 'id' (a nil value)` crash at line 613 | The ebook button (`book_detail.lua:651`) wraps its callback as `{ item = real_item, ebook_only = true }`. The initial `onBookTap` callback unwraps this correctly, but the 3 re-push sites (completion, cancel, delete-then-repush) used `function(b) self:_onDownloadBook(b) end` which passed the envelope table as the `item` parameter — it has no `.id` field. | Changed all 3 re-push callbacks to `function(data) local book_item = data.item or data; local ebook_only = data.ebook_only or false; self:_onDownloadBook(book_item, ebook_only) end` |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/library_browser.lua` | Fixed 3 re-push `on_download` callbacks (lines ~775, ~812, ~900) to unwrap `{ item, ebook_only }` envelope |
| `spec/test_library_browser.lua` | Added regression test asserting no raw-pass callbacks exist and all unwrapping callbacks present |

## Open Items & Next Steps

- [ ] Consider refactoring the unwrapping into a shared helper to avoid duplicating the same 4-line pattern at every call site
- [ ] Pre-existing `test_manifest.lua` failure (`getRecentBook` returns table instead of nil) — unrelated, needs separate fix

---

*Log written by write-log skill*
