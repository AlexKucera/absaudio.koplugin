# Issue #25 — Trim Downloader Bloat: Dead Code + Misplaced Utilities

> **Date:** 2026-06-11
> **Type:** issue
> **Reference:** [Issue #25](https://github.com/AlexKucera/absaudio.koplugin/issues/25)

## Goal

Trim `downloader.lua` (the largest module at 763 lines) down to its essential responsibilities by removing dead code, relocating a misplaced utility, and consolidating duplicated download logic.

## What Was Done

### 1. Deleted Dead Code: `build_download_request()` (and bonus: `build_range_header()`)

**Finding:** `build_download_request()` had zero production callers — only 2 test cases referenced it. `start_chunked_download()` uses `chunked_http.download()` directly, bypassing this function entirely.

**Bonus finding:** `build_range_header()` also had zero production callers — its logic was inlined into both `_download_one_file()` and `start_chunked_download()`. Only 4 test cases called it.

**Action:** Deleted both functions (36 + 12 = **48 lines removed**) and their 6 tests.

### 2. Relocated `format_bytes()` to `widget_helpers`

**Finding:** `format_bytes()` is a pure formatting utility with no downloader-specific dependencies. `widget_helpers.lua` already hosts sibling formatters (`format_file_size`, `format_duration`, `format_time`). Additionally, `download_progress.lua` had its own local copy of the same function (triplication).

**Action:**
- Added `format_bytes(b)` to `widget_helpers.lua` (with improved nil/0/negative handling)
- Changed `downloader.format_bytes` to a re-export delegating to `widget_helpers.format_bytes`
- Updated `book_detail.lua` to call `widget_helpers.format_bytes()` directly
- Replaced `download_progress.lua`'s local copy with `require("absaudio/widget_helpers")`
- Moved format_bytes test from `test_downloader.lua` to `test_widget_helpers.lua` (7 tests)
- Net: **-25 lines** from downloader, **-9 lines** from download_progress

**Gotcha:** Moving format_bytes introduced a transitive dependency on KOReader's `ffi/blitbuffer` module (required by widget_helpers). Had to add ~45 lines of mock stubs to `test_downloader.lua` so it could load widget_helpers through the re-export.

### 3. Consolidated Legacy Download Functions

**Finding:** `execute_download()` and `execute_single_file_download()` shared ~80% identical body:
- mkdir → determine open_mode (wb/ab) → Range header for resume → open file → create sink → API call → close file → update manifest status

**Action:** Extracted `_download_one_file(entry, file, deps)` shared helper containing the common body. Both functions now delegate:
- `execute_download()` — loops over files, tracks cancellation/progress, calls `_download_one_file` per iteration
- `execute_single_file_download()` — single-line delegation to `_download_one_file`

Net: **-38 lines** from removing duplication (new helper + trimmed execute functions)

### 4. Trimmed Verbose Doc Blocks

Several doc blocks were excessively verbose (15+ lines each with redundant parameter descriptions). Trimmed 4 doc blocks for a net saving of **~27 lines**.

## Acceptance Criteria Status

| # | Criteria | Status |
|---|----------|--------|
| 1 | Confirm `build_download_request` has no callers; delete if dead | ✅ Deleted (also deleted bonus dead `build_range_header`) |
| 2 | Move `format_bytes` to widget_helpers; update all callers | ✅ Moved; 3 callers updated (downloader→re-export, book_detail, download_progress) |
| 3 | Extract shared `_download_one_file()` helper | ✅ Both `execute_*` delegate to it |
| 4 | All 77+ existing downloader tests pass | ✅ **82 pass** (5 new `_download_one_file` tests added) |
| 5 | Net line reduction ≥100 from downloader.lua | ✅ **763 → 660 = -103 lines** |

## Test Changes

| File | Δ Tests | Notes |
|------|---------|-------|
| `test_downloader.lua` | -6 / +5 = **-1 net** (82 total) | Removed 2 `build_download_request`, 4 `build_range_header`, 1 `format_bytes`; added 5 `_download_one_file` |
| `test_widget_helpers.lua` | **+7** (38 total) | New `format_bytes` test suite (nil, 0, negative, bytes, KB, MB, GB) |

## Files Modified

| File | Change |
|------|--------|
| `absaudio/downloader.lua` | **-103 lines** (763→660): deleted 2 dead functions, extracted helper, trimmed docs, re-exported format_bytes |
| `absaudio/widget_helpers.lua` | **+18 lines**: added `format_bytes()` |
| `absaudio/book_detail.lua` | **1 line**: changed `downloader.format_bytes` → `widget_helpers.format_bytes` |
| `absaudio/download_progress.lua` | **-9 lines**: replaced local `format_bytes` copy with `require("absaudio/widget_helpers")` |
| `spec/test_downloader.lua` | **-2 tests, +5 tests**: removed dead code tests, added `_download_one_file` suite; added KOReader mocks for widget_helpers dep |
| `spec/test_widget_helpers.lua` | **+7 tests**: `format_bytes` test suite |

## Decisions & Rationale

- **Re-export pattern for `format_bytes`**: Rather than update every caller of `downloader.format_bytes` across the codebase, kept a backward-compatible re-export. This avoids breaking any external consumers and makes the migration safe.
- **`_download_one_file` as private function** (underscore prefix): Signals this is an internal implementation detail, not part of the public API.
- **Bonus dead code removal**: `build_range_header` was not in the original issue scope but was clearly dead (only test callers). Removing it reduced risk of future developers calling it instead of using the inlined logic.

## Gotchas

- **Transitive KOReader dependency**: `widget_helpers` requires `ffi/blitbuffer` at load time. When `downloader.lua` started transitively loading `widget_helpers` via the re-export, `test_downloader.lua` broke because it didn't stub `ffi/blitbuffer`. Fix: added comprehensive KOReader mock stubs to the test setup block (~45 lines of mocks).
- **`format_bytes` nil handling**: The original `downloader.format_bytes` returned `"0 B"` for 0 but crashed on `nil`. The new `widget_helpers.version` handles `nil`, `0`, and negative values gracefully. Test updated accordingly.

## Next Steps

- Consider whether `start_chunked_download` should also delegate to `_download_one_file` for its file-open/setup phase (currently duplicates the mkdir/open_mode/Range logic)
- Downloader module is now focused on download orchestration rather than mixing in formatting utilities

## Statistics

- **Lines removed from downloader.lua:** 103 (763 → 660)
- **Tests passing:** 82 downloader, ~279 total (2 pre-existing logger failures unrelated)
- **GitNexus index:** 695 nodes, 701 edges (post-change)
