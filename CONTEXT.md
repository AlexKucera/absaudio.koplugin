# absaudio.koplugin — Domain Glossary

## Scope

- **v1**: Personal-use plugin for PocketBook Era. Hosted privately on GitHub.
- **Quality bar**: Proper error handling and config UX despite personal scope.
- **No multi-device support** in v1. PocketBook inkview FFI only.
- **Future**: May be shared publicly if it proves stable in personal use.

## Terms

### Audiobook
A library item in ABS containing one or more audio files (M4B, MP3, etc.). The plugin downloads **all** audio files for a selected book into a single folder and plays them as a playlist via inkview's `LoadPlaylist()` / `PlayTrack(n)`. A single-file M4B is a degenerate playlist of length 1.

### Download directory
First download prompts user to pick a base folder via KOReader's folder picker. Saved to config as `download_dir`. Subsequent downloads auto-create subfolders. User can change `download_dir` anytime via plugin settings UI (ships in v1).

**Folder naming:** `{download_dir}/{sanitized_author}_{sanitized_title}/` — e.g., `/mnt/ext1/audiobooks/Andy_Weir_Project_Hail_Mary/`. Author + title avoids collisions between same-named books by different authors.

**File sanitization:** ABS filenames are sanitized before writing to disk:
- Spaces → underscores
- Strip characters outside: alphanumeric, `.`, `-`, `_`, `(`, `)`
- Preserve original file extension
- Truncate long names to ~120 characters

### Download behavior
**Background download** via **coroutine + chunked reads** (proven KOReader pattern). HTTP stream read in small chunks (~8-16KB) inside a coroutine; after each chunk, update progress bar widget and yield to KOReader's event loop. Each chunk read micro-freezes for milliseconds — imperceptible to user. Non-blocking in practice.

On re-download, **prompt before overwriting** existing files ("Already downloaded. Re-download?").

**Download resume (two-layer):**
- **File-level tracking:** each file's `status` field is `complete`, `partial`, or `pending`. Already-complete files are skipped on retry.
- **Byte-level resume for partial files:** sends HTTP `Range: bytes=<N>-` header to ABS to continue where the download broke. Falls back to re-downloading the partial file from scratch if ABS doesn't support Range.
- **Transient WiFi hiccups** are handled the same way as a full disconnect — retry resumes automatically.

### Manifest
Local state file tracking downloaded books. One entry per book (not per file). Stores:
- `abs_item_id` — ABS library item ID
- `title`, `local_dir` — book folder path
- `files` — ordered list of `{filename, size, type, status}` for all files (`status`: `"complete"`, `"partial"`, `"pending"`)
- `current_time` — **global position in seconds** from start of book (ABS-compatible scalar)
- `duration` — total duration in seconds
- `chapters` — `{ id, title, start, end }[]` from ABS (for navigation display)
- `is_finished`, `last_synced_at`

Playback converts global position → (track index + offset) for inkview seeking. Sync sends/receives global position directly to ABS.

### Configuration
Auto-created on first run (no template file). Edited via in-app settings UI or directly as Lua.

**Settings:**
- `server` — ABS server URL (required)
- `token` — API key (required)
- `download_dir` — Base directory for downloads (prompted on first download, changeable in settings)
- `preferred_format` — Audio format preference, **defaults to `"m4b"`**. When ABS offers multiple audio files per book, downloads only files matching this extension. If no match found, **falls back to `"mp3"`**. If neither available, downloads all audio files.
- `log_level` — Logging verbosity: `"verbose"`, `"info"`, or `"warn"`. Defaults to `"verbose"`.

**Actions (not settings):**
- Delete downloaded audiobook — removes all local files (audio + ebooks) + manifest entry together. Accessed from book detail view for downloaded books.

### Ebook/PDF support
ABS library items can include ebook files (PDF, EPUB) alongside audio files. Downloaded **independently** from audio — separate download buttons, separate state tracked in manifest per file.
- Audio files → playback via inkview
- PDF/ebook files → open in KOReader's native `ReaderUI:showReader()` (same post-download pattern naleo already uses)
- Detail view shows two file sections: **Audio files** and **Ebook/PDF files**, each with appropriate actions (download/play vs. download/open)

### Sync conflict resolution
**Default: furthest position wins** — compare local `current_time` with server's `currentTime`, keep the higher one.
**Exception:** if server reports `isFinished == true` and local position is **earlier**, prompt user before overwriting ("You finished this book on another device. Overwrite progress?"). Prevents accidental loss of completion marker during re-listens.

### Dashboard (main screen)
Top-level view on plugin open. Four sections:
- **Resume last book** — quick-action button for the most recently played audiobook (tap to resume immediately)
- **Downloaded books** — list of all downloaded/incomplete audiobooks with local progress badges (title, duration, current position, finished status; incomplete downloads show "Resume" action)
- **Browse library** — navigates to ABS library browser (explicit action, not the default view)
- **Settings** — server URL, token, download directory, preferred format, **Sync now** action

### Sync triggers (v1)
- **Manual "Sync now"** — push + pull on user demand
- **Timer during playback** — push position to ABS every 60s while audio is active
- **On playback start** — pull from ABS for that book (catches progress from other devices). If offline, play from last known local position — never block playback.
- **On plugin exit / suspend** — push current position as safety net
- **NOT in v1:** pull-on-browse, background progress for undownloaded books

### Offline behavior
Plugin degrades gracefully when ABS server is unreachable:
- **Dashboard** — resume + downloaded books work from local manifest. **Browse library** and **Sync now** are greyed out/disabled.
- **Playback** — starts from last local position. Sync-on-start is silently skipped.
- **Sync timer during playback** — silently skips push attempt. Position is saved to manifest locally; will sync next successful connection.
- **Download stalls mid-file (WiFi drop)** — partial file is tracked in manifest with download progress state. Offers **resume download** on retry (also handles transient WiFi hiccups).
- **KOReader killed / suspend / battery die during download** — on next plugin open, **scan manifest entries against actual files on disk**: if a file's actual size doesn't match its expected size from ABS, mark it as `partial`. Show incomplete downloads in dashboard's downloaded books list with a **"Resume"** badge/action. **Never auto-start resume** — user must tap to continue.
- **Book detail (not downloaded)** — cannot show metadata or initiate download. Show offline message.
- **Settings** — all fields editable locally. "Sync now" shows connection error toast.

### Error handling policy
**Never crash KOReader.** Every failure path shows a user-facing dialog or toast with a plain-language message.

**Network failures:** retry with **exponential backoff** (configurable: max retries, initial delay, backoff multiplier). UI shows progress/retry state during retries.

**API error responses:**
- 401/403 → "Check your server URL and API token in Settings."
- 404 on progress → expected (no progress yet), handle silently
- 404 on item/library → "Item not found on server. It may have been removed."
- 5xx → treat as transient, apply retry-with-backoff
- Malformed/unexpected JSON → log warning, show "Unexpected response from server"

**File system errors:**
- Disk full → "Not enough space to download. Free up storage and try again."
- Permission denied → "Cannot write to this location. Choose a different folder in Settings."
- Manifest corrupted → recreate from scratch (loss of local progress only; ABS still has it)

**Playback errors** (blocked on hardware, pattern designed now):
- File not found → "Audio file missing. It may have been deleted. Try re-downloading."
- Unsupported codec → "This audio format is not supported by your device."
- Inkview call fails → "Playback error. Restart KOReader and try again."

### Background download implementation
Coroutine-based chunked download:
- HTTP stream read in 8-16KB chunks inside a Lua coroutine
- After each chunk: write to disk, update progress bar widget, yield to event loop
- Progress bar shows: current file / total files, bytes downloaded / total bytes, percentage + ETA
- Cancel button on progress dialog (stops after next chunk completes)
- For multi-file downloads: sequential (one file after another), not parallel

### Repository
**Built from scratch** as a new KOReader plugin. `naleo/audiobookshelf.koplugin` used as **reference material only** (not a code fork). Reason: ~93% of the final codebase is new or so heavily rewritten that forking adds overhead without benefit. What we reuse from naleo: the `_meta.lua` boilerplate, proof that `socketutil` + Bearer auth works on PocketBook, and the ABS URL/response patterns.

Repo: private GitHub repository initially. Directory name: `absaudio.koplugin`.

### Chapters
ABS provides `media.chapters` — array of `{ id, title, start, end }` in seconds. **Full chapter navigation in v1:**
- **Detail view** — show chapter list as a tappable table of contents. Tapping a chapter seeks playback to that position.
- **During playback** — display current chapter name (e.g., "Chapter 3: The Wildfire"). Next/prev chapter skip controls.
- **Manifest** — stores `chapters` array fetched from ABS alongside book metadata.

### Cover art
**Full color JPEG covers everywhere** — PocketBook Era Color supports color display. Covers fetched from ABS via `GET /api/items/{id}/cover`.

**Storage:** cached alongside downloads as `{local_dir}/cover.jpg`. Fetched once, stored permanently. Displayed in:
- **Dashboard** — thumbnail next to "Resume last book" + in downloaded books list
- **Library browser** — thumbnail per book in list
- **Detail view** — large cover image at top

**Fetch strategy:**
- Downloaded books: load `cover.jpg` from local disk (no network needed)
- Undownloaded books (library browser): fetch on demand, cache locally even without downloading audio
- If cover fetch fails (offline, network error): show placeholder/blank, never block UI
- Deleted when book is deleted (lives in book folder)

### First-run experience
No config file detected → **settings dialog opens automatically** with empty fields (server, token). User enters credentials, plugin validates by calling `GET /api/libraries`. On success → save config → proceed to dashboard. On failure → show "Connection failed. Check your server URL and token." with retry option. No separate wizard widget — keep it simple.

### Library browser
Forked from naleo's pattern, enhanced for ~220-book library:

**Search:** text field at top of library browser. Passes `search=` query param to ABS `GET /api/libraries/{id}/items`. Filters list client-side as user types (or re-fetches on submit — decide during implementation based on latency).

**Sort:** tap-to-cycle button. Cycles through: title ↑ / title ↓ / author ↑ / author ↓ / recently added / recently played. Applied client-side after the single fetch.

**Pagination:** **fetch all items from ABS in one API call** (`limit=500` or no limit), store full result set locally, then present **paginated** (~20–30 items per page) with **"Load more"** button at bottom. No re-fetching when paging — all sorting/filtering is client-side against the cached result set.

### Logging
**Configurable log levels** via KOReader's built-in `logger`:
- **`verbose`** — every API request/response summary, every position update, every coroutine yield, download chunk progress. Default during development.
- **`info`** — lifecycle events (plugin start/stop, API calls made, download started/completed, sync push/pull, playback state changes). Good for daily use.
- **`warn`** — only warnings and errors. Minimal noise for stable operation.
- **Setting:** `log_level` in config, defaults to `"verbose"`. User can change in settings UI or edit config file directly.

**Export diagnostics** action in settings:
- Bundles into a single file: recent log entries + config (server URL present, token redacted) + manifest summary (item IDs and titles only, no paths) + device info (KOReader version, plugin version)
- Saved to `{download_dir}/diagnostics-{timestamp}.txt`
- User can pull off device via USB for debugging or bug reports

### Plugin identity
- **Display name:** ABS Audio (shown in KOReader plugin menu)
- **Directory name:** `absaudio.koplugin`
- **Versioning:** Semantic versioning (`MAJOR.MINOR.PATCH`), stored in `main.lua`. Displayed in settings UI.
- **Updates:** Manual only — user pulls latest from GitHub repo (USB or WiFi transfer). No auto-update or GitHub API check.

### Playback UX
**Playback screen = detail view** — when audio is playing, the book's detail view transforms into a now-playing view:
- Large **play/pause** button (center)
- **Skip backward 30s** / **skip forward 30s** buttons
- Progress bar (seekable) with current position / duration display
- Current chapter name below progress bar
- Cover art visible at top
- Chapter list tappable for seek-to-chapter
- **Sleep timer** button → opens timer picker (see Sleep timer below)
- **Playback speed** button → tap-to-cycle through presets: 0.5×, 0.75×, 1×, 1.25×, 1.5×, 1.75×, 2×. Current speed shown as badge. Default 1×. **Local preference only — not synced to ABS.**

**On book completion:** auto-mark `isFinished = true` locally, push to ABS on next sync cycle, stop playback, return to dashboard. No confirmation dialog, no next-book suggestion.

**Physical page-turn buttons:** no action during playback. KOReader handles them normally.

### Sleep timer
Configurable timer that pauses playback after a set duration or at chapter end:
- **Time presets:** 15 minutes, 30 minutes, 45 minutes, 1 hour
- **"End of chapter" option** — waits until current chapter finishes, then pauses. Uses `media.chapters` data to determine chapter boundary.
- **UI:** countdown shown in playback view (e.g., "Sleep in 23:45" or "Sleep at end of chapter"). Tap to cancel or adjust.
- **When timer fires:** pause playback (do not close/exit). User can resume normally.
- **If "end of chapter" is set and user seeks to a different chapter:** recalculates based on new chapter's end position.

### Playback (blocked on hardware)
Via PocketBook inkview FFI (`PlayFile`, `LoadPlaylist`, `GetTrackPosition`, etc.). Playlist model preferred; falls back to single-file `PlayFile()` if playlist APIs don't work from KOReader context. **Cannot be tested until device arrives.**
