# Issue #5: Download Pipeline — Acceptance Criteria Audit & Gap Close

> **Date:** 2026-06-10
> **Type:** issue
> **Reference:** [GitHub Issue #5](https://github.com/AlexKucera/absaudio.koplugin/issues/5)

## Goal

Audit all 13 acceptance criteria for Issue #5 (download pipeline) against the current codebase, identify gaps, and close them with TDD.

## What Was Done

- Audited all 13 acceptance criteria systematically against the codebase
- Found 12 of 13 criteria already met; 1 gap: **"Open Ebook" button** — ebooks could be downloaded but had no way to open in KOReader's reader after download
- Added "Open Ebook" button to `BookDetailView._addEbookFiles()` that appears when ebook files are complete
- Fixed `_itemFromManifest()` to reconstruct `media.ebookFile` from manifest ebook entries (so ebook section renders correctly when viewing downloaded books offline)
- Wired `on_open_ebook` callback through `detail.show()` → `_renderView()` → `BookDetailView` → all 5 `nav.push("detail", ...)` call sites in `library_browser.lua`
- Implemented `_onOpenEbook(filepath)` on `LibraryBrowserView` — calls `ReaderUI:showReader(filepath)`
- Removed emoji from "Delete ebook" button (TextWidget can't render emojis per AGENTS.md learnings)
- Wrote 3 TDD tests (RED → GREEN cycle) for the new functionality
- Final test suite: **309 tests pass, 0 failures** (up from 306)

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| No auto-open after ebook download | User explicitly requested no auto-open; instead added a manual "Open Ebook" button |
| Button uses `ReaderUI:showReader()` | KOReader's canonical API for opening documents; handles EPUB, PDF, and all supported formats; shows error if format unsupported |
| `on_open_ebook` as callback pattern | Consistent with existing `on_download`/`on_delete` callback pattern; keeps `book_detail.lua` unaware of ReaderUI |
| Reconstruct `ebookFile` in `_itemFromManifest` | Without this, viewing a downloaded book offline would lose ebook section because the reconstructed item lacked `media.ebookFile` |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| "Open Ebook" tests failing — ebook section not rendered | `detail.prepare()` takes offline path → `_itemFromManifest()` → returned item without `media.ebookFile` → `_addEbookFiles` saw no ebook files | Reconstructed `media.ebookFile` from manifest ebook entries in `_itemFromManifest()` |
| Emojis in button text don't render | AGENTS.md documents this: TextWidget can't render emojis; must use IconWidget with built-in icon names | Removed emoji from "Delete ebook" button text; used plain text for "Open Ebook" |
| Initial debug showed view had only 8 items (no ebook section) | The manifest fallback path (`_itemFromManifest`) was stripping `ebookFile` from the item, so the ebook section was never populated | Same fix as above — reconstruct `ebookFile` from manifest |

## Acceptance Criteria Final Status

| # | Criterion | Status |
|---|-----------|--------|
| 1 | Download All Audio downloads every audio file sequentially | ✅ PASS |
| 2 | Format preference applied (m4b → mp3 → all) | ✅ PASS |
| 3 | Progress widget shows file/total, bytes/total, %, ETA, cancel | ✅ PASS |
| 4 | Cancel stops after current chunk (no corruption) | ✅ PASS |
| 5 | Partial files resumed via HTTP Range header | ✅ PASS |
| 6 | Already-complete files skipped | ✅ PASS |
| 7 | Re-download prompts user before overwriting | ✅ PASS |
| 8 | Free space checked; warning if insufficient | ✅ PASS |
| 9 | Incomplete downloads detected on startup | ✅ PASS |
| 10 | Ebook/PDF downloadable independently; opens in reader | ✅ PASS |
| 11 | Delete removes all files + manifest entry atomically | ✅ PASS |
| 12 | Unit tests pass for format preference and filename sanitization | ✅ PASS |
| 13 | Full pipeline works in KOReader emulator | ⏭️ MANUAL |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/book_detail.lua` | Added "Open Ebook" button in `_addEbookFiles`; fixed `_itemFromManifest` to reconstruct `media.ebookFile`; threaded `on_open_ebook` through `show`/`_renderView`; removed emoji from "Delete ebook" |
| `absaudio/library_browser.lua` | Added `_onOpenEbook(filepath)` method calling `ReaderUI:showReader()`; added `on_open_ebook` callback to all 5 `nav.push("detail", ...)` call sites |
| `spec/test_book_detail.lua` | 3 new tests: Open Ebook button appears when complete, doesn't appear when not downloaded, callback receives correct file path |

## Open Items & Next Steps

- [ ] Manual emulator testing of the full download pipeline against a real ABS server (criterion #13)
- [ ] Test "Open Ebook" button in emulator to verify ReaderUI integration works end-to-end
- [ ] Consider adding an icon (via `IconWidget`) for the "Open Ebook" button instead of plain text

---

*Log written by write-log skill*
