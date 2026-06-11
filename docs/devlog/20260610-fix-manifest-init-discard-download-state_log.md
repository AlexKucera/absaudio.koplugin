# Fix: manifest.init() discarding download state + checkerboard cover after download

> **Date:** 2026-06-10
> **Type:** issue
> **Reference:** Bug report — download succeeds but book detail shows "Download" instead of "Downloaded"; cover image shows checkerboard

## Goal

Fix two bugs that appeared after a successful audiobook download:
1. Book detail view shows "Download" button instead of "Downloaded" status after download completes
2. Cover image replaced by checkerboard (broken image) after download completes

## What Was Done

- **Made `manifest.init()` idempotent** — added early return `if settings then return end` so re-calling init() doesn't discard in-memory LuaSettings state
- **Added `settings:flush()` calls** to all mutating manifest functions (`addBook`, `updateBook`, `removeBook`, `updateFileStatus`, `updatePosition`) so changes persist to disk across sessions
- **Added `manifest.flush()`** public API for callers that need explicit disk persistence
- **Added `manifest._resetSettings()`** to allow tests to reset the singleton and re-init from scratch
- **Added existence check for `cover.jpg`** in `book_detail._addCoverArt()` — verifies file exists via `lfs.attributes()` before using it as the image path, falling through to cover_cache or "No Cover" placeholder when absent
- **Added 3 regression tests** in `spec/test_manifest.lua` covering the exact bug scenario

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Make `init()` idempotent rather than removing re-calls | Less invasive — many callers (`detail.show()`, `_addCoverArt()`, `_addDownloadStatus()`) all call `manifest.init()` defensively. Making it a no-op after first call is the safest fix. |
| Flush after every mutation | KOReader's `LuaSettings:saveSetting()` is purely in-memory. Without `flush()`, crashes lose all state. Trade-off: slightly more disk I/O, but audiobook downloads are infrequent and the data is small. |
| Existence check for cover.jpg rather than downloading cover | The download pipeline only downloads audio files, not cover art. The cover is already cached by `cover_cache`. Adding a download step would be scope creep — just verify the file exists before using it. |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| Book detail shows "Download" after successful download | `manifest.init()` called `LuaSettings:open()` on every invocation, which re-reads from disk via `dofile()`. The download pipeline updated the in-memory settings (via `addBook`, `updateFileStatus`) but never flushed. The next `init()` in `detail.show()` created a brand-new LuaSettings from disk, discarding all download state. | Made `init()` return immediately if `settings` is already set. Added `flush()` calls to all mutating functions. |
| Cover shows checkerboard after download | `_addCoverArt()` constructs `cover_path = book.local_dir .. "/cover.jpg"` when a manifest entry exists. But `cover.jpg` was never downloaded — only the `.m4b` file. ImageWidget renders a nonexistent path as a checkerboard. | Added `lfs.attributes(candidate, "mode") == "file"` check before using the path. Falls through to `cover_cache` lookup (which has the cached cover) or "No Cover" placeholder. |
| Pre-existing test failures in test_manifest.lua (3 tests) | State leakage between tests — `mock_settings` accumulates entries from earlier tests. Not related to this session's changes. | Not fixed in this session — pre-existing, filed as tech debt. |

## Files Changed

| File | Change Summary |
|------|---------------|
| `manifest.lua` | Made `init()` idempotent (early return if already initialized); added `flush()` to all mutation functions; added public `manifest.flush()` and `manifest._resetSettings()` APIs |
| `absaudio/book_detail.lua` | Added `lfs.attributes()` existence check before using `cover.jpg` path in `_addCoverArt()` |
| `spec/test_manifest.lua` | Added 3 regression tests: init() idempotency, _resetSettings, flush-on-mutation |

## Open Items & Next Steps

- [ ] Pre-existing test_manifest.lua failures from state leakage between tests (3 tests: `getAllBooks`, `getRecentBook` × 2)
- [ ] Consider downloading cover art into `local_dir/cover.jpg` during the download pipeline (would make offline cover display work without cover_cache)
- [ ] Verify fix on device/emulator end-to-end (download a book → detail view shows "Downloaded" + cover)

---

*Log written by write-log skill*
