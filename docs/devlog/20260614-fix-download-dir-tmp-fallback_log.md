# Fix: Download Dir Silent /tmp Fallback Strands Downloads

> **Date:** 2026-06-14
> **Type:** generic
> **Reference:** device-reported (#3 of three device issues)

## Goal

On the PB700K3, a downloaded audiobook was reported complete but was **not findable** via Finder. Diagnosis (on-device probe) showed the file landed at `/tmp/audiobooks/…` even though the user had since set `download_dir = /mnt/ext1/audiobooks` in settings. Root cause: `downloader.lua` fell back to `"/tmp/audiobooks"` whenever `download_dir` was unset — which it was at download time. On PocketBook `/tmp` is not exposed via USB mass storage and may be tmpfs (gone after reboot), so downloads vanished from the user's view. Eliminate the silent `/tmp` fallback; use a persistent KOReader data dir instead. The default also prefers the PocketBook native-player directory (`/mnt/ext1/Audio Books`) when it exists, so the stock audiobook player picks up downloads too — giving free native-player fallback playback + USB/Finder visibility.

## What Was Done

- **`config.lua` — two new functions:**
  - `config.default_download_dir()` → prefers **`/mnt/ext1/Audio Books`** (the PocketBook native-player scan dir, USB-visible as `/Volumes/PB700K3/Audio Books`) when it exists; otherwise `<koreader_data_dir>/absaudio_books` (resolves via `DataStorage:getFullDataDir()`, falling back to `getDataDir()` then `getSettingsDir()`). Persistent, writable, USB-visible. **Never `/tmp`.** Dir-existence is checked via the injectable `config._exists_dir` (lfs-based default) so tests can stub it without touching the filesystem.
  - `config.get_download_dir()` → returns the configured value when set & non-empty, otherwise the persistent default (does not persist it — the settings UI / caller decides).
- **`absaudio/downloader.lua` — removed the `/tmp` fallback** at both call sites (`prepare_download` and `prepare_ebook_download`): `config.get("download_dir") or "/tmp/audiobooks"` → `config.get_download_dir()`.
- **`main.lua` — settings dialog pre-fill:** the "Download Directory" field now defaults to `config.default_download_dir()` when unset, so the user is shown the persistent location as a suggested value (the "prompt").
- **Tests:** `spec/test_config.lua` +4 (default path, configured-wins, unset→default, whitespace→default); `spec/test_downloader.lua` mock configs updated to expose `get_download_dir` (10 sites).

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Persistent default via `DataStorage:getFullDataDir()`, not a directory-picker dialog | Resolves the landmine deterministically and is unit-testable (mock DataStorage). A full directory-picker (`OpenDirectorySelector`) was considered but adds async/UI coupling to the synchronous `prepare_download` contract; the pre-filled settings field already lets the user choose. A picker remains a possible follow-up. |
| `get_download_dir()` does NOT auto-persist the default | Keeps the function pure and testable; persistence happens only when the user confirms in Settings. Avoids writing settings on every download. |
| Lazily resolve DataStorage methods (`getFullDataDir` → `getDataDir` → `getSettingsDir`) | Different KOReader builds expose different subsets; degrade to the next persistent root rather than crash. |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| Downloaded file invisible in Finder despite "complete" status | `downloader.lua` silently fell back to `/tmp/audiobooks` when `download_dir` unset; `/tmp` is not USB-exposed and may be tmpfs | Persistent `default_download_dir()`; removed `/tmp` fallback; pre-fill Settings field |
| Also: re-download was blocked because the manifest recorded status `complete` | `isDownloaded == true` short-circuits | Workaround for existing stranded download: Delete (book detail) then Download again — now goes to the persistent dir. The manifest fix is handled by the delete/re-download flow. |

## Files Changed

| File | Change Summary |
|------|---------------|
| `config.lua` | +`default_download_dir()`, +`get_download_dir()` (persistent default, never `/tmp`) |
| `absaudio/downloader.lua` | Both `prepare_*` functions: `/tmp` fallback → `config.get_download_dir()` |
| `main.lua` | Settings "Download Directory" field pre-fills with `config.default_download_dir()` |
| `spec/test_config.lua` | +4 tests; mock DataStorage exposes `getFullDataDir` |
| `spec/test_downloader.lua` | 10 mock configs expose `get_download_dir` |

## Verification

- `busted spec/test_config.lua` → **18 passed, 0 failed** (4 new).
- `busted spec/test_downloader.lua` → **82 passed, 0 failed** (no regressions).
- Full suite → only the 7 pre-existing `InfoMessage nil` failures in `test_library_browser` remain (unrelated, documented open).
- `grep '/tmp/audiobooks'` in `absaudio/` + `main.lua` → **0 matches** (landmine removed).

## Open Items & Next Steps

- [ ] User: delete the stranded `/tmp/audiobooks/…` book in book-detail, then re-download — it should now land under `<koreader_data_dir>/absaudio_books/…` and be Finder-visible (USB mount of `/mnt/ext1`).
- [ ] Consider adding an `OpenDirectorySelector`-based picker to Settings as a follow-up (richer "prompt" than the pre-filled text field).
- [ ] Related issue still open (separate work): no audible sound — backend selection + native audio stack investigation (see probe work).

---

*Log written by write-log skill*
