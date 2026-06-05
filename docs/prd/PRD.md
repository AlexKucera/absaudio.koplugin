# PRD: ABS Audio — KOReader Plugin for PocketBook Era Color

## Problem Statement

I own a self-hosted Audiobookshelf (ABS) server with ~220 audiobooks (primarily single-file M4B). I listen on my phone via the official ABS app, but I want to also listen on my PocketBook Era Color e-reader — which has color display, touchscreen, and built-in audio playback capability. There is no existing KOReader plugin that can browse an ABS server, download audiobooks, play them on-device, and sync playback position back to ABS so progress is consistent across devices.

## Solution

A KOReader plugin ("ABS Audio") built from scratch for PocketBook Era Color, using `naleo/audiobookshelf.koplugin` as reference material only (not a code fork). Provides: background download with resume, inkview FFI-based audio playback, chapter navigation, sleep timer, playback speed control, and bidirectional progress sync to ABS. The plugin presents a dashboard-oriented UI (not library-browser-as-root) because its primary value is local playback + sync, not remote catalog browsing.

## User Stories

### Setup & Configuration

1. As a first-time user, I want the plugin to open a settings dialog automatically so I can enter my ABS server URL and API token without hunting for config files.
2. As a user, I want the plugin to validate my credentials when I save settings (by calling the ABS API) so I know immediately if something is wrong.
3. As a user, I want to configure where downloaded files are stored on my device, using a folder picker the first time and a settings field thereafter.
4. As a user, I want to set a preferred audio format (defaulting to M4B) so the plugin downloads the right version when ABS offers multiple formats per book.
5. As a developer testing this plugin, I want configurable log levels (verbose/info/warn) so I can get detailed diagnostics during development and minimal noise during daily use.
6. As a user encountering issues, I want an "Export diagnostics" action in settings that bundles logs + sanitized config into a file I can pull off the device for debugging.

### Browsing & Discovery

7. As a user opening the plugin, I want to see a dashboard showing my most recently played book (for quick resume), all my downloaded books with progress, and entry points for browsing my library and adjusting settings.
8. As a user browsing my ABS library, I want to see all audiobooks (not filtered to ebooks) with duration displayed in human-readable format (e.g., "12h 30m").
9. As a user browsing my library, I want to search by title or author so I can find books quickly across 220+ items.
10. As a user browsing my library, I want to tap a sort button to cycle through sorting options (title, author, recently added, recently played).
11. As a user browsing my library, I want results paginated (~20-30 items per page) with a "Load more" button rather than waiting for all 220 books to render at once.
12. As a user tapping a book in any list, I want to see its detail view with cover art, metadata, audio files, ebook/PDF files, and chapters listed clearly.
13. As a user viewing a book's details, I want to see full-color cover art from ABS cached locally so the list is visually scannable.
14. As a user viewing a book's details, I want to see which audio files match my preferred format highlighted so I know what will be downloaded by default.

### Downloading

15. As a user wanting to download a book, I want to download **all** audio files for that book into a single organized folder, not just one file, because some of my audiobooks have multiple parts.
16. As a user downloading a book, I want to see a progress bar updating in real-time while the download runs, with the ability to cancel it.
17. As a user whose WiFi drops mid-download, I want the plugin to track partial downloads and offer a seamless resume when connectivity returns — including HTTP Range requests to avoid re-downloading completed bytes.
18. As a user trying to re-download a book I already have, I want to be prompted before existing files are overwritten so I don't accidentally lose my place.
19. As a user who also wants the accompanying PDF/ebook for an audiobook, I want to download it independently from the audio files and open it directly in KOReader's reader.
20. As a user reopening the plugin after a crash or suspend mid-download, I want to see incomplete downloads flagged with a Resume option — the plugin should detect partial files by comparing manifest records against actual disk sizes.
21. As a user about to download a large file, I want to be warned if there isn't enough free space on my device.
22. As a user managing storage, I want to delete a downloaded audiobook (all audio + ebook files) from within the plugin, with the manifest cleaned up atomically so there are no orphaned entries.

### Playback

23. As a user tapping Play on a downloaded audiobook, I want it to start playing immediately through the device's native audio player.
24. As a user resuming a book, I want playback to start from wherever I left off — whether that position was set locally on this device or synced from another device via ABS.
25. As a user listening to a multi-file audiobook, I want files to play sequentially as a playlist without gaps or manual intervention between files.
26. As a user listening, I want a big play/pause button, skip forward/backward 30 seconds buttons, and a seekable progress bar showing current position and total duration.
27. As a user listening, I want to see the current chapter name below the progress bar so I know where I am in the book's structure.
28. As a user looking at the chapter list, I want to tap any chapter to seek directly to that position.
29. As a user listening, I want next/prev chapter skip controls to jump between chapter boundaries.
30. As a user who prefers faster listening, I want to cycle through playback speeds (0.5× – 2×) with a single tap.
31. As a user who listens before bed, I want a sleep timer that pauses playback after 15/30/45/60 minutes or at the end of the current chapter.
32. As a user with a sleep timer active, I want to see the remaining time countdown on the playback screen and be able to cancel or adjust it.
33. When a book finishes playing, I want it auto-marked as finished (locally and synced to ABS) and playback to stop — no confirmation dialog needed.
34. As a user listening offline (no WiFi), I want playback to work normally from my last known position — never blocked by network unavailability.

### Sync

35. As a user who listened on my phone this morning, I want the PocketBook to pull the latest progress from ABS when I start playing a book, so I resume at the right spot.
36. As a user listening on the PocketBook, I want my position pushed to ABS every 60 seconds so my phone always knows where I am.
37. As a user manually triggering "Sync Now", I want both push (local → ABS) and pull (ABS → local) to happen in one operation.
38. As a user who finished a book on my phone and started re-listening on the PocketBook, I want to be warned before my completion marker is overwritten — "You finished this book on another device. Overwrite progress?"
39. When two devices report different positions, I want the plugin to keep the furthest position (the one farthest along in the book) since that represents the most listening done.
40. When the plugin exits or KOReader suspends, I want my current position saved locally and pushed to ABS as a safety net.
41. As a user offline (no WiFi, ABS unreachable), I want sync attempts to silently fail without blocking playback or showing errors — just save position locally and sync when connectivity returns.
42. As a user offline, I want library browse and sync actions visibly disabled/greyed out so it's clear they require connectivity.

## Implementation Decisions

### Module Architecture

The plugin is structured as a fork of `naleo/audiobookshelf.koplugin` with significant additions. Modules fall into four categories:

**Core infrastructure** (deep modules, testable interfaces):
- **Config manager** — auto-creates config on first run, reads/writes `server`, `token`, `download_dir`, `preferred_format`, `log_level`. Validates credentials against ABS on save. Settings UI uses KOReader's `MultiInputDialog` pattern (same as upstream).
- **API client** (`api.lua`) — wraps all 7 ABS endpoints with retry-with-backoff, timeout management via `socketutil`, Bearer token auth. Forked from upstream's `audiobookshelfapi.lua` with ebook filters removed and 3 new endpoints added (progress GET/PATCH, items-in-progress). All requests go through `pcall` — no unhandled crashes.
- **Manifest** (`manifest.lua`) — CRUD for per-book state stored via `LuaSettings`. Each entry tracks: ABS item ID, title, author, local directory, ordered file list (with type, size, download status), global position (seconds), duration, chapters array, finished flag, last-sync timestamp. This is the single source of truth for all local state.
- **Error handler** — centralized error dialog helper. Maps HTTP status codes to user-facing messages. Wraps every external call (API, filesystem, FFI). Never allows a crash to propagate to KOReader.
- **Logger** — configurable verbosity wrapper around KOReader's `logger`. Three levels: verbose (every request/response, every position update), info (lifecycle events, key operations), warn (errors only).

**UI layer** (KOReader widgets):
- **Dashboard widget** — root view on plugin open. Four sections: Resume Last Book (quick-action), Downloaded Books (list with progress badges and cover thumbnails), Browse Library (navigation entry), Settings (config fields + Sync Now + Export Diagnostics). Stubbed "Resume" button in Phase 2, fully wired in Phase 6.
- **Library browser** — KOReader Menu widget for browsing ABS libraries and items. Search field, tap-to-cycle sort, client-side pagination (fetches all items once, pages locally), duration formatting, cover art thumbnails. Structure pattern referenced from naleo's browser.
- **Detail view** — adaptive single widget. Shows different action sets based on download state. Not downloaded: metadata, cover art, audio file list (format/size, preferred format highlighted), ebook/PDF file list, chapter list (tappable for seek-to-chapter), download buttons (audio + PDF independent). Downloaded: same metadata plus play/resume button, delete button, progress badge, format-as-now-playing view (progress bar, play/pause, ±30s skip, speed control, chapter name, sleep timer, chapter list).
- **Download progress widget** — modal/cancellable dialog showing: current file / total files, bytes downloaded / total bytes, percentage, ETA, cancel button. Updated each coroutine chunk yield.

**Playback** (hardware-dependent, isolated behind interface):
- **Player** (`player.lua`) — LuaJIT FFI wrapper around PocketBook inkview audio API. Interface: `play(playlist_path)`, `pause()`, `resume()`, `stop()`, `close()`, `getPosition()` → seconds, `setPosition(global_seconds)`, `getDuration()` → seconds, `getCurrentTrack()` → index, `getPlaybackSpeed()` / `setPlaybackSpeed(multiplier)`. Internally handles global-position ↔ (track, offset) conversion, playlist loading via `LoadPlaylist()`, fallback to single-file `PlayFile()` if playlist APIs fail.
- **Chapter navigator** — pure logic module (no FFI dependency). Given a chapters array and a global position, returns current chapter index/name, next/prev chapter, seeks to chapter start. Used by both detail view (chapter list) and playback view (current chapter display).

**Sync** (thin layer over API client):
- **Sync module** (`sync.lua`) — `pullProgress(item_id)` (GET from ABS, update manifest if ahead), `pushProgress(item_id)` (PATCH to ABS from manifest/player). Contains conflict resolution logic: compare local vs server `currentTime`, keep furthest, guard `isFinished=true` with confirmation dialog. Offline-aware: returns success/failure without blocking caller.

**Download pipeline** (coroutine-based):
- **Downloader** — coroutine-driven chunked HTTP download. Per-book orchestration: iterate files in order, skip `complete` files, Range-resume `partial` files, download `pending` files. Each file: open HTTP stream, read 8-16KB chunks in coroutine, write to disk, update progress widget, yield after each chunk. Handles cancellation (stops after current chunk). Format preference filtering applied when selecting which files to download.

### Key Data Shapes

**Manifest entry (per book):**
```
{
  abs_item_id: string,
  title: string,
  author: string,
  local_dir: string,              -- "{download_dir}/{SanitizedAuthor}_{SanitizedTitle}/"
  files: [{
    filename: string,
    size: number,
    type: "audio" | "ebook",
    status: "complete" | "partial" | "pending"
  }],
  current_time: number,           -- global position in seconds (scalar, ABS-compatible)
  duration: number,               -- total seconds
  chapters: [{ id, title, start, end }],  -- from ABS media.chapters
  is_finished: boolean,
  last_synced_at: number          -- unix timestamp
}
```

**Config:**
```
{
  server: string,                 -- ABS URL (required)
  token: string,                  -- API key (required)
  download_dir: string,           -- base path (set on first download)
  preferred_format: string,       -- "m4b" (default) | "mp3" | ...
  log_level: string               -- "verbose" (default) | "info" | "warn"
}
```

**Sync conflict result:** `{ action: "keep_local" | "keep_server" | "prompt_user", position: number, is_finished: boolean }`

### API Contract (ABS endpoints used)

All requests use `Authorization: Bearer <token>` header.

| Method | Endpoint | Purpose | Body |
|---|---|---|---|
| GET | `/api/libraries` | List libraries (filter `mediaType=="book"`) | — |
| GET | `/api/libraries/:id/items?limit=500&sort=&search=` | List all items in library (fetch-all, paginate client-side) | — |
| GET | `/api/items/:id?expanded=1` | Get item details + audio files + chapters | — |
| GET | `/api/items/:id/file/:ino?token=` | Download specific file (binary stream) | — |
| GET | `/api/me/progress/:id` | Get progress for item | — |
| PATCH | `/api/me/progress/:id` | Update progress | `{ currentTime, duration, progress, isFinished }` |
| GET | `/api/me/items-in-progress` | Get items with progress | — |
| GET | `/api/items/:id/cover` | Get cover image (JPEG) | — |

### File/Folder Naming Convention

- Book folder: `{download_dir}/{sanitized_author}_{sanitized_title}/`
- Sanitization: spaces → underscores, strip chars outside `[a-zA-Z0-9._()-]`, truncate to ~120 chars, preserve extension
- Cover: `{local_dir}/cover.jpg`

### Offline Behavior Matrix

| Feature | Online | Offline |
|---|---|---|
| Dashboard resume | Pulls latest position, plays | Plays from last local position |
| Dashboard downloaded list | Normal (local data) | Normal (local data) |
| Browse library | Full functionality | Entry greyed out, disabled |
| Detail view (downloaded) | Full: play, delete, sync | Play/delete work; sync shows error toast |
| Detail view (not downloaded) | Metadata + download buttons | "Connect to WiFi to browse" message |
| Download | Full pipeline | Cannot start; shows offline message |
| Download in-progress (WiFi drops) | Resumes via Range | Waits for connectivity, then resumes |
| Settings | All editable | All editable; "Sync Now" shows error |
| Sync timer (60s) | Pushes position | Silently skips, saves locally |
| Sync on exit | Pushes position | Saves locally only |
| Playback | Normal | Normal (fully local) |

### Error Handling Policy

Every failure path produces a user-facing dialog or toast. No silent failures except:
- Sync timer ticks during offline (save locally, skip push)
- Cover image fetch failure (show placeholder)

Retry behavior: exponential backoff on all network failures (configurable max retries, initial delay, multiplier). UI shows retry state during attempts.

HTTP error responses:
- 401/403 → "Check your server URL and API token in Settings."
- 404 on progress → expected (no progress yet), handle silently
- 404 on item/library → "Item not found on server. It may have been removed."
- 5xx → transient, apply retry-with-backoff
- Malformed JSON → log warning, show "Unexpected response from server"

Filesystem errors:
- Disk full → "Not enough space. Free up storage and try again."
- Permission denied → "Cannot write here. Choose a different folder in Settings."
- Manifest corrupted → recreate from scratch (loss of local progress only; ABS still authoritative)

### Sleep Timer Presets

Time-based: 15 min, 30 min, 45 min, 60 min. Chapter-end: waits until current chapter's `end` position, then pauses. If user seeks to a different chapter while chapter-end timer is active, recalculates based on new chapter boundary. Timer fires → pause only (does not exit or close).

### Playback Speed Presets

0.5×, 0.75×, 1×, 1.25×, 1.5×, 1.75×, 2×. Tap-to-cycle button. Default 1×. Stored as local preference only — not synced to ABS (position scalar remains consistent regardless of speed on either device).

## Testing Decisions

### What makes a good test

Tests verify external behavior, not implementation details. A test for the API client should assert "calling getLibraries returns a parsed table of libraries" not "calls socket.http with these exact parameters." A test for the manifest should assert "after adding a book, getBook(id) returns it" not "writes a Lua table to this file path."

### Which modules will be tested

| Module | Test priority | Rationale |
|---|---|---|
| Manifest (CRUD) | High | Pure logic, no hardware/FFI dependency. Easy to unit test. Core data model. |
| Conflict resolution | High | Pure function (two positions → decision). Edge cases matter (isFinished guard, equal positions, zero positions). |
| Global ↔ track+offset conversion | High | Pure math. Must be correct for sync integrity. Test with edge cases (position at track boundary, position beyond last track, single-track book). |
| Chapter navigator | Medium | Pure logic (position → chapter lookup). Test boundary conditions (exactly at chapter start/end, beyond last chapter). |
| Sanitization | Medium | Pure function (string → string). Test with spaces, unicode, special chars, long names, collisions. |
| Format preference filter | Low-Medium | Pure logic (file list + preference → filtered list). Easy to test. |
| API client | Low | Requires mock HTTP or running ABS server. Integration test territory. |
| Player / Downloader | Cannot unit-test | Require hardware (player) or real filesystem/network (downloader). Tested manually on device. |

### Prior art for tests

No existing test framework in the reference plugin (naleo). KOReader itself has some tests under `spec/` using a custom assertion library. Tests for this plugin will follow KOReader's patterns where they exist, otherwise use simple Lua `assert()`-based test scripts runnable with `lua` or `luajit`.

## Out of Scope

- Multi-device support (Kobo, Android, etc.) — v1 is PocketBook Era Color only via inkview FFI
- Localization / i18n — personal-use plugin, English only
- Auto-update mechanism — manual GitHub pull only
- Keyboard shortcuts or physical button mapping — Era has touchscreen + two page-turn buttons; all interaction is touch-driven
- ABS session lifecycle API — using lightweight Media Progress API instead
- OPDS feed support — direct ABS REST API only
- Social features (ratings, reviews, series tracking in UI) — ABS supports these but not in v1 scope
- Podcast support — ABS handles podcasts but this plugin targets audiobooks (`mediaType == "book"`)
- CI/CD pipelines — personal private repo
- Coupling to stradichenko/audiobook.koplugin — confirmed to be a TTS engine, not relevant

## Further Notes

### Repository

New GitHub repository (`absaudio.koplugin`), built from scratch. `naleo/audiobookshelf.koplugin` used as reference material only. Private repository initially.

### Versioning

Semantic versioning (`MAJOR.MINOR.PATCH`). Stored in `_meta.lua` and a version file. Displayed in settings UI.

### ADRs Recorded

Six architectural decisions recorded in `docs/adr/`:

| ADR | Decision |
|---|---|
| [0001](docs/adr/0001-global-position-in-manifest.md) | Global position (seconds) stored in manifest, not track+offset pair. Optimizes sync path. |
| [0002](docs/adr/0002-playlist-model-for-playback.md) | Playlist model for all playback, even single-file books. Shapes entire player architecture. |
| [0003](docs/adr/0003-sync-conflict-resolution.md) | Furthest-wins with isFinished guard for sync conflicts. Prevents re-listen data loss. |
| [0004](docs/adr/0004-dashboard-as-root-navigation.md) | Dashboard as root view, not library browser. Deviates from upstream pattern. |
| [0005](docs/adr/0005-coroutine-chunked-download.md) | Coroutine + chunked reads for background downloads. Deviates from upstream's blocking approach. |
| [0006](docs/adr/0006-from-scratch-not-fork.md) | From-scratch implementation, not a fork of naleo's plugin. ~93% new code made forking counterproductive. |

### Hardware Dependencies

Phases 1–3 are fully buildable and testable without a PocketBook device (API calls hit a real ABS server over WiFi). Phase 4 (playback) requires the actual PocketBook Era Color to test inkview FFI calls. Phases 5–6 require Phase 4 to be complete but individual pieces (sync conflict logic, timer code) can be unit-tested independently.

### Domain Glossary

Full glossary maintained in [`CONTEXT.md`](CONTEXT.md). Key terms: Audiobook, Download directory, Download behavior, Manifest, Configuration, Ebook/PDF support, Sync conflict resolution, Dashboard, Library browser, Chapters, Playback, Cover art, First-run experience, Logging, Plugin identity, Playback UX, Sleep timer.
