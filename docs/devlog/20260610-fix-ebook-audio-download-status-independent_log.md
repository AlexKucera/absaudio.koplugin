# Fix ebook/audio download status tracked independently

> **Date:** 2026-06-10
> **Type:** issue
> **Reference:** Bug report from user testing

## Goal

Fix the book detail view showing incorrect download status when an ebook is downloaded for a book that already has an audiobook downloaded. The audiobook and ebook download statuses should be tracked and displayed independently.

**Symptoms reported:**
- Downloading an ebook → book detail shows "audiobook downloaded" instead of ebook status
- Ebook still shows download button after successful download
- Cancelling an ebook download → audiobook shows as "partially downloaded"
- Audio and ebook download states overwrite each other

## What Was Done

- **Root cause identified:** `manifest.addBook()` uses `abs_item_id` as the sole key, so `prepare_ebook_download` overwrote the audiobook manifest entry with an ebook-only entry, destroying all audio file status
- **Fixed `downloader.prepare_download`** (audio) to merge audio files into existing manifest entries instead of replacing them; checks for existing entry, skips already-tracked files by `ino`, creates fresh entry only when none exists
- **Fixed `downloader.prepare_ebook_download`** to merge ebook files into existing manifest entries; same merge pattern as audio
- **Rewrote `book_detail:_addDownloadStatus`** from a single 3-state badge to per-type tracking: computes `audio_state` and `ebook_state` independently from manifest file entries (using `type` field with `"audio"` default for backward compat)
- **Added `book_detail:_addAudioDownloadStatus`** sub-section showing "Audio downloaded" / "Audio download incomplete" / "Audio not downloaded" with type-specific action buttons ("Delete audio", "Resume audio", "Download audio")
- **Updated `book_detail:_addEbookFiles`** to check per-file download status from manifest, show ✓/⚠ per file, "Download Ebook"/"Resume ebook" only when not downloaded, "Delete ebook" when complete
- **Updated delete callbacks** to pass `{ item = item, ebook_only = bool }` envelope so audio and ebook deletion are independent
- **Added `library_browser:_onDeleteEbookOnly`** — removes only ebook files from manifest, preserves audio
- **Fixed `reconcile_manifest`** — `fs:get_file_size(path)` → `fs.get_file_size(path)` (pre-existing bug: Lua `:` operator passed `fs` table as first arg to plain function, causing `lfs.attributes(table)` crash on startup)
- **Fixed 3 pre-existing manifest test failures** — tests were missing `manifest._resetSettings()` calls, causing leaked state between tests
- **Added 3 regression tests** in `spec/test_downloader.lua` (slices 11-13)

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Merge into existing manifest entry instead of separate entries | One manifest entry per `abs_item_id` keeps the data model simple; the manifest already supports multiple files per entry, so adding a `type` field to each file was the minimal change |
| Files without `type` field default to `"audio"` | Backward compatibility with existing manifest data on devices — old entries don't have `type` and are all audio |
| Per-type status badges instead of combined | Users need to see at a glance whether audio and/or ebook are downloaded; a combined badge would hide this information |
| `{ item, ebook_only }` envelope in callbacks | Consistent with the existing download callback pattern; avoids adding more callback parameters |
| Skip `fs:get_file_size` → `fs.get_file_size` | The `fs` table contains plain functions, not methods; using `:` passes self as first arg which corrupted the path parameter |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| Ebook download destroyed audio manifest entry | `manifest.addBook(entry)` overwrites by key; `prepare_ebook_download` created a fresh entry that replaced the audio one | Check for existing entry first; merge new files in instead of replacing |
| Cancel ebook made audiobook show "partial" | Same overwrite — cancel set ebook file to "partial" but the overwrite made it the only file, so status check saw "partial" as the overall state | Per-type status tracking means ebook partial doesn't affect audio state |
| `lfs.attributes` crash on plugin init ("string expected, got table") | `reconcile_manifest` called `fs:get_file_size(path)` — Lua `:` sugar passes `fs` table as first arg to the plain `get_file_size` function, so `lfs.attributes(fs_table)` was called | Changed to `fs.get_file_size(path)` (dot notation, no self) |
| `prepare_download returns error when book already downloaded` test broke | Refactored `prepare_download` moved `isDownloaded` check after `getBook` check; test item had no `audioFiles` so hit `no_audio_files` before reaching `isDownloaded` | Added early `isDownloaded` fallback when no audio files in item data and existing entry exists |
| 3 manifest tests (`getAllBooks`, `getRecentBook`) always failed | Tests didn't call `manifest._resetSettings()` so `manifest.init()` was a no-op on subsequent calls, leaking state from prior tests | Added `manifest._resetSettings()` before `manifest.init()` in the 3 affected tests |
| Existing `prepare_download resets partial files to pending` test asserted wrong behavior | Test was documenting the bug (partial→pending reset) as expected behavior; fix made partial status be preserved | Updated test assertion to expect partial status preserved |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/downloader.lua` | `prepare_download` and `prepare_ebook_download` merge into existing entries; fixed `fs:get_file_size` → `fs.get_file_size` |
| `absaudio/book_detail.lua` | Per-type download status (`_addDownloadStatus` + `_addAudioDownloadStatus`); ebook section shows per-file status and type-aware buttons |
| `absaudio/library_browser.lua` | Delete/download callbacks unwrap `{ item, ebook_only }` envelope; new `_onDeleteEbookOnly` method |
| `spec/test_downloader.lua` | 3 new tests (slices 11-13): merge ebook into audio, cancel preserves audio, merge audio into ebook |
| `spec/test_book_detail.lua` | Updated badge text assertions to match new per-type labels; moved summary to end |
| `spec/test_manifest.lua` | Added `manifest._resetSettings()` to 3 tests that were leaking state |

## Open Items & Next Steps

- [ ] Test on device with existing manifest data to verify backward compat (files without `type` field)
- [ ] Verify ebook-only delete works end-to-end in emulator
- [ ] The `_addEbookFiles` per-file status display (✓/⚠) was not tested through the UI mock — only the data layer is tested in `test_downloader.lua`

---

*Log written by write-log skill*
