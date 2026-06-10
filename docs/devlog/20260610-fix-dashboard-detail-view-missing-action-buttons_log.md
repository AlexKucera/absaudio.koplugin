# Fix: Dashboard book detail view missing action buttons

> **Date:** 2026-06-10
> **Type:** generic
> **Reference:** User-reported via screenshot comparison

## Goal

Diagnose and fix why tapping a downloaded book on the **dashboard** showed a stripped-down detail view (no Download audio, Open Ebook, or Delete buttons) compared to the **library browser's** detail view which showed all action buttons.

## What Was Done

- **Diagnosed root cause:** Same `BookDetailView` class (`absaudio/book_detail.lua:120`) is used by both callers, but `DashboardView:_onBookTap` passed a minimal stub item `{id, title, author}` with zero callbacks. Every action button in BookDetailView is guarded by `if self.on_download / self.on_delete / self.on_open_ebook`, so they were silently skipped.
- **Rewrote `_onBookTap` in `dashboard_widget.lua`:** Now builds an enriched `detail_item` from manifest data (duration, chapters, files, local_dir, media shape) and passes all three callback functions (`on_download`, `on_delete`, `on_open_ebook`).
- **Added `_onDownloadBook()` to DashboardView:** Full download pipeline mirroring LibraryBrowserView — free space check → progress widget → schedule_next loop with 0.05s delay → detail view refresh on completion/cancel. Handles both audio and ebook-only downloads.
- **Added `_onDeleteBook()` to DashboardView:** Delete with ConfirmBox dialog; handles full-book deletion (via `downloader.delete_book`) and ebook-only deletion (removes ebook files from manifest + disk); refreshes detail view after each path.
- **Added `_onOpenEbook()` to DashboardView:** Delegates to `ReaderUI:showReader(filepath)`.
- **Added new imports:** `absaudio/downloader` and `absaudio/download_progress` modules (guarded with pcall).
- **Added test:** `_onBookTap passes on_download/on_delete/on_open_ebook callbacks` — verifies callbacks are functions and item is enriched with duration, chapters, local_dir, media shape.

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Mirror download/delete handlers in dashboard rather than extracting shared module | The handlers are tightly coupled to their parent widget (`self_ref` for re-push callbacks). Extracting would require passing a widget ref or callback factory — not worth the indirection for ~200 lines of straightforward code. Can refactor later if a third caller appears. |
| Enrich manifest book into API-like item shape in `_onBookTap` | BookDetailView expects `item.audioFiles`, `item.ebookFiles`, `item.media.chapters`, etc. Manifest books store data flat (`duration`, `chapters`, `files`). Mapping at the call site keeps BookDetailView unchanged. |
| Use `scheduleIn(0.05)` for download pump loop | Per project learning from cancel-download-hang fix: `scheduleIn(0)` starves UIManager event loop. 0.05s gives ~20 pumps/sec while keeping UI responsive. |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| Syntax error `')' expected near ']'` at line 674 | The `gmatch` pattern for path splitting got corrupted during edit — `[^/]` became `[^"` inside the string literal, breaking Lua parser | Fixed pattern to `"[^/]+"` |
| Missing `end` for `onClose()` function | When replacing the `function DashboardView:onClose()` anchor line with the new handler methods, the original function body (just `end`) was consumed by the replace_lines operation | Re-added `function DashboardView:onClose() end` block |
| Lua reserved keyword as table key in test | Test used `{ start = 0, end = 1800 }` — `end` is a reserved word in Lua and cannot be used as an unquoted table key | Changed to `{ ["end"] = 1800 }` |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/dashboard_widget.lua` | Added downloader/progress imports; rewrote `_onBookTap` to pass enriched item + 3 callbacks; added `_onDownloadBook`, `_onDeleteBook`, `_onOpenEbook` methods (~260 lines net addition) |
| `spec/test_dashboard_widget.lua` | Added test verifying `_onBookTap` wires callbacks and enriches item data (+1 test, 16 total) |

## Open Items & Next Steps

- None. The dashboard→detail path now matches library→detail for all visible elements.

---

*Log written by write-log skill*
