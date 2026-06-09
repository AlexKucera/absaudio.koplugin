# Issue #18: Book Detail Data/Render Split

> **Date:** 2026-06-09
> **Type:** issue (architecture deepening)
> **Reference:** https://github.com/AlexKucera/absaudio.koplugin/issues/18

## Goal

Split the book detail widget's data preparation from its rendering by extracting a `detail.prepare(item)` function. The data-fetching logic (API call, manifest fallback, merge) should live in `prepare()`, while `show()` handles async orchestration and widget rendering.

## What Was Done

- Extracted `detail.prepare(item)` as a synchronous public function in `absaudio/book_detail.lua`
- `prepare()` handles: API fetch + merge → manifest fallback → basic item return → error
- Refactored `detail.show()` to call `prepare()` instead of the previous inline `_fetchAndShow`/`_showFromManifestOrError` logic
- `show()` preserves the async pattern: loading indicator + `scheduleIn` for API path, sync for offline
- Added 4 new tests for `detail.prepare()` covering all data paths
- Removed 59 lines of mixed data/render code, replaced with 25 lines of clean separation
- All 172 tests pass (15 in test_book_detail, 157 in other test files)

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| `prepare()` is synchronous | Keeps data logic testable without async machinery; async orchestration stays in `show()` where it belongs |
| `prepare()` returns `(data, nil)` or `(nil, error_info)` | Consistent return pattern with error info table for error_handler consumption |
| Manifest fallback inside `prepare()` | Data fallback is a data-layer concern, not a rendering concern |
| Basic item return when item has title/media | Graceful degradation — show what we have rather than erroring |
| Kept `_mergeItemData` and `_itemFromManifest` as internal functions | They're still called from `prepare()` but are now behind the public interface |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| Test expected `data.duration` but `_itemFromManifest` returns `data.media.duration` | Manifest data puts duration inside the media table | Fixed test assertion to check `data.media.duration` instead of `data.duration` |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/book_detail.lua` | Added `detail.prepare()`, refactored `detail.show()` to use `prepare()` |
| `spec/test_book_detail.lua` | Added 4 tests for `detail.prepare()` (API success, manifest fallback, error, offline basic) |

## Open Items & Next Steps

- None — all acceptance criteria for Issue #18 are met
- Parent epic #11 continues with remaining architecture deepening items

---

*Log written by write-log skill*
