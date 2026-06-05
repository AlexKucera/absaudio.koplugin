# absaudio.koplugin — Planning Spec

## Project summary

A KOReader plugin for PocketBook Era that connects to a self-hosted Audiobookshelf server, lets you browse and download audiobooks directly on the e-reader, plays them through PocketBook's native audio player, and syncs playback position back to ABS so you can pick up where you left off on any device.

This spec builds on an earlier planning session done in Perplexity (attached separately), revising its recommendations after reading the actual source code of the referenced projects.

**The approach:** Build from scratch as a KOReader plugin, using `naleo/audiobookshelf.koplugin` as reference material (not a code fork). The reference proves `socketutil` + Bearer auth works on PocketBook KOReader, provides ABS URL/response patterns, and shows `_meta.lua` / `MultiInputDialog` / `LuaSettings` conventions. New modules: an inkview FFI wrapper for PocketBook's built-in audio player, a local manifest for tracking downloads and position, a coroutine-based download pipeline with resume, and a thin sync layer that pushes/pulls progress via ABS's Media Progress API.

**Key findings from research:**
- naleo/audiobookshelf.koplugin is a solid fork target — ~600 lines of working code covering browse→detail→download, with the ebook restriction isolated to 3 lines of code
- stradichenko/audiobook.koplugin is a TTS plugin (text-to-speech read-aloud), NOT an audio file player — irrelevant to this project despite the misleading name
- PocketBook's inkview SDK exposes a full audio player API (`PlayFile`, `GetTrackPosition`, `SetTrackPosition`, `GetPlayerState`) accessible via LuaJIT FFI from KOReader — this solves the playback and position capture problem with ~50 lines of code
- ABS's Media Progress API (`PATCH /api/me/progress/:id`) is the right sync mechanism for v1 — one HTTP call with five fields, no need for the heavier Session lifecycle

**Estimated effort:** 3–4 weekends for a working personal plugin.

---

## Strategic assessment

The Perplexity session did solid research and identified the right pieces. But after looking at the actual code of the existing projects, I'd shift the strategy in three important ways.

### 1. Reference naleo's plugin — confirmed after reading all source code

I've now read every file in naleo/audiobookshelf.koplugin. Here's what it actually is:

**Structure (7 files, ~600 lines total):**

```
audiobookshelf.koplugin/
├── _meta.lua                              # Plugin descriptor
├── main.lua                               # Entry point (36 lines)
├── audiobookshelf_config.example.lua      # Config template: { token, server }
├── audiobookshelf_version.lua             # Version: { 0, 1, 3 }
└── audiobookshelf/
    ├── audiobookshelfapi.lua              # HTTP client (190 lines)
    ├── audiobookshelfbrowser.lua          # Library + item browser (233 lines)
    ├── bookdetailswidget.lua              # Book detail view (326 lines)
    └── ebookfilewidget.lua                # Download widget (263 lines)
```

**What it does well (reusable as-is):**

- Uses KOReader's `socketutil` for timeout management on top of `socket.http` — this is the correct approach (the Perplexity skeleton used raw `socket.http` without timeout management)
- Uses `NetworkMgr:runWhenOnline()` to ensure connectivity before browsing
- Library browser uses KOReader's `Menu` widget with proper level navigation (libraries → books)
- In-app settings dialog for server URL + API token (via `MultiInputDialog`)
- Search within a library
- Download flow with folder picker, filename editor, overwrite check
- Cover image loading and display via `RenderImage`
- All HTTP uses Bearer token auth correctly

**What's hardcoded for ebooks (needs changing):**

1. **API filter in `audiobookshelfapi.lua` line 51:** `local filters = "ebooks." .. "ZWJvb2s%3D"` — this is a base64-encoded ABS filter that restricts results to items with ebook files. Applied in both `getLibraryItems()` and `getSearchResults()`. **Remove this filter** to see audiobook items.

2. **File type filter in `bookdetailswidget.lua` line 103:** `if file.fileType == "ebook" then` — only shows ebook files in the detail view. **Change to show audio files** (`file.fileType == "audio"` or check for audio extensions).

3. **Post-download action in `ebookfilewidget.lua` line 135:** `ReaderUI:showReader(path .. "/" .. safeFilename)` — opens the downloaded file in KOReader's ebook reader. **Replace with audio playback** via inkview `PlayFile()`.

**What's worth noting (not blockers, but good to know):**

- Downloads are synchronous and blocking. Fine for a 2MB epub, potentially problematic for a 500MB M4B. May need a background download approach later.
- Config is a raw Lua file (not integrated into KOReader's global settings). This is actually clean — keeps plugin state self-contained.
- The API module creates a new `LuaSettings` from the config file path using `debug.getinfo(1).source` to find its own directory. Works but is a bit fragile.
- No pagination on library item listing (`limit=0` means "all items"). Fine for small libraries, might be slow for 500+ books.

**Verdict:** Excellent reference material for KOReader/ABS integration patterns. However, after full design (see PRD.md), ~93% of the final codebase is new or so heavily rewritten that forking adds overhead without benefit. Build from scratch, keep naleo's source open for pattern reference. See ADR-0006.

### 2. Use the simpler progress API, not sessions

The ABS API has two progress mechanisms:

- **Playback Sessions** — heavyweight, tracks individual listening activities with device info, play method, time-listened-per-session. This is what the official ABS mobile app uses.
- **Media Progress** — lightweight, just `currentTime`, `duration`, `progress` (0–1), `isFinished`. One PATCH call updates it.

The Perplexity session's skeleton tried to use sessions, which adds complexity you don't need for a v1. The Media Progress endpoint (`PATCH /api/me/progress/:libraryItemId`) is purpose-built for third-party clients doing offline playback. One HTTP call, five fields, done.

### 3. Don't try to integrate audiobook.koplugin as a dependency

The Perplexity session suggested reusing audiobook.koplugin (stradichenko) as the playback layer. After looking at it, I'd advise against coupling to it:

- It's at v0.1.9 — still unstable and rapidly changing
- It's designed as a standalone plugin with its own UI, state, and lifecycle — not as a library
- The coupling surface (hooking into its player callbacks to capture position) would be fragile

Instead: for PocketBook, the device has a native audio player. For KOReader on other devices, there may be Lua audio libraries. The safest v1 playback strategy is the simplest one that works on your specific hardware. Prove it first, abstract later.


## What already exists (landscape summary)

| Project | What it does | What you reuse |
|---|---|---|
| naleo/audiobookshelf.koplugin | KOReader plugin: browse ABS libraries, download ebook files. 7 files, ~600 lines. Hardcoded ebook filter in 2 places | Reference only (not a fork). Take patterns: socketutil+Bearer auth, _meta.lua template, MultiInputDialog/LuaSettings conventions, ABS URL shapes. ~93% of final codebase is new. |
| stradichenko/audiobook.koplugin | KOReader plugin: TTS read-aloud with word highlighting (NOT an M4B player) | Nothing. Wrong tool — it synthesizes speech, doesn't play audio files |
| PocketBook inkview SDK (libinkview) | Native firmware API with PlayFile, GetTrackPosition, SetTrackPosition, etc. | **Your playback layer.** Call via LuaJIT FFI from KOReader — already loaded |
| J-Lich/abs-kosync-bridge | Server-side: maps ABS audio timestamps to EPUB positions via Whisper | Complementary. Run it server-side if you want audiobook↔ebook sync. No plugin integration needed |
| koreader/koreader-sync-server | Server-side: KOSync protocol for ebook progress sync | Reference only. Your plugin syncs directly to ABS, not KOSync |


## ABS API surface (the 6 calls you need)

All requests use `Authorization: Bearer <api_key>` header.

### 1. List libraries
```
GET /api/libraries
→ { libraries: [{ id, name, mediaType, ... }] }
```
Filter for `mediaType == "book"` (ABS uses "book" for audiobooks too; the distinction is in the media files).

### 2. List items in a library
```
GET /api/libraries/:libraryId/items?limit=50&page=0&sort=media.metadata.title
→ { results: [{ id, media: { metadata: { title, authorName }, duration, audioFiles, ... } }] }
```

### 3. Get item details (expanded)
```
GET /api/items/:itemId?expanded=1
→ { id, media: { audioFiles: [{ ino, metadata: { filename, ext, size } }], duration, chapters }, ... }
```
This gives you the audio file list and chapter data.

### 4. Download an audio file
```
GET /api/items/:itemId/file/:fileIno?token=<api_key>
→ binary audio stream
```
Note: file download uses the `ino` (inode number) of the specific file, not a track index. The token can go as a query parameter for downloads.

### 5. Get current progress for an item
```
GET /api/me/progress/:libraryItemId
→ { id, currentTime, duration, progress, isFinished, lastUpdate, ... }
```
Returns 404 if no progress exists yet.

### 6. Update progress
```
PATCH /api/me/progress/:libraryItemId
Content-Type: application/json
{ "currentTime": 3845.5, "duration": 29400, "progress": 0.1308, "isFinished": false }
```
Creates or updates. This is the only sync call you need for v1.

### Bonus: Get "continue listening" items
```
GET /api/me/items-in-progress
→ { libraryItems: [{ id, media, ... }] }
```
Useful for a "resume" screen showing what's in progress across your library.


## Plugin architecture

Built from scratch. `naleo/audiobookshelf.koplugin` used as reference for KOReader/ABS integration patterns.

```
absaudio.koplugin/
├── _meta.lua                         # Plugin descriptor (KOReader convention)
├── main.lua                          # Entry point: menu registration, first-run check
├── config.lua                        # Config manager: auto-create, validate, read/write
├── api.lua                           # ABS API client: all 8 endpoints with retry/backoff
├── manifest.lua                     # Local state: per-book CRUD via LuaSettings
├── error_handler.lua                # Centralized error dialogs (never crash)
├── logger.lua                       # Configurable verbosity wrapper
├── absaudio/
│   ├── dashboard_widget.lua         # Root view: resume + downloaded + library + settings
│   ├── library_browser.lua           # ABS library/item browser with search/sort/paginate
│   ├── detail_view.lua               # Adaptive widget: downloaded vs not-downloaded modes
│   ├── download_progress_widget.lua # Cancellable progress bar dialog
│   ├── downloader.lua               # Coroutine chunked download pipeline
│   ├── player.lua                   # Inkview FFI wrapper (hardware-dependent)
│   ├── chapter_navigator.lua        # Pure logic: position ↔ chapter mapping
│   ├── sleep_timer.lua              # Sleep timer logic (time presets + chapter-end)
│   ├── sync.lua                     # Push/pull progress to/from ABS
│   └── util/
│       └── sanitization.lua         # Filename/folder name sanitization
```

### Reference patterns taken from naleo

- `_meta.lua` structure and fields → plugin registration format
- `socketutil:set_timeout()` + `pcall()` HTTP pattern → proven on PocketBook
- Bearer token auth header construction (`Authorization: Bearer <token>`)
- ABS endpoint URL shapes and response JSON structures
- `MultiInputDialog` usage for in-app settings UI
- `LuaSettings` for persistent config storage
- `RenderImage` / `ImageWidget` for cover art display
- Folder picker via `FileManagerChooser:showChooseDialog`
- `ReaderUI:showReader()` for opening PDF/ebook files post-download

### Core data model

**manifest.lua** — Local state per downloaded book:
```lua
{
  ["item-id-abc"] = {
    title = "Project Hail Mary",
    author = "Andy Weir",
    local_dir = "/mnt/ext1/audiobooks/Andy_Weir_Project_Hail_Mary/",
    files = {
      { filename = "Project_Hail_Mary.m4b", size = 482000000, type = "audio", status = "complete" },
      { filename = "Bonus_Interview.mp3", size = 24000000, type = "audio", status = "complete" },
      { filename = "Supplementary.pdf", size = 5200000, type = "ebook", status = "complete" },
    },
    current_time = 3845.5,     -- global position in seconds
    duration = 21600,          -- total seconds
    chapters = {{ id=1, title="Part 1", start=0, end=3600 }, ...},
    is_finished = false,
    last_synced_at = 1717300000,
  }
}
```

**player.lua** — Inkview FFI wrapper (~120 lines):
```lua
ffi.C.PlayFile(path)           -- or LoadPlaylist(path)
ffi.C.PausePlaying()
ffi.C.ResumePlaying()
ffi.C.GetTrackPosition()      -- returns ??? (units TBD on hardware)
ffi.C.SetTrackPosition(pos)
ffi.C.GetTrackLength()        -- total duration of current track
ffi.C.StopPlaying()
ffi.C.ClosePlayer()
ffi.C.SetPlaybackSpeed(speed) -- 0.5 .. 2.0
ffi.C.GetPlaybackSpeed()
-- Playlist variants if available:
ffi.C.LoadPlaylist(playlist_path_or_list)
ffi.C.PlayTrack(n)             -- 0-indexed?
ffi.C.NextTrack()
ffi.C.PreviousTrack()
```

**downloader.lua** — Coroutine-based download pipeline:
- Per-book orchestration: iterate files, skip complete, Range-resume partial, download pending
- Each file: HTTP stream → 8-16KB chunks → write disk → update progress → yield
- Cancel button stops after current chunk
- Format preference filter (m4b → mp3 → all)

**sync.lua** — Progress push/pull to ABS:
- `pullProgress(item_id)` → GET /api/me/progress/{id} → update manifest if server ahead
- `pushProgress(item_id)` → PATCH /api/me/progress/{id} with {currentTime, duration, progress, isFinished}
- Conflict resolution: furthest-wins + isFinished guard

## Build order

Each phase produces something testable. Phases 1–3 require no hardware; Phase 4 requires PocketBook Era.

### Phase 1: Foundation (no hardware)

1. Initialize new KOReader plugin repo (`absaudio.koplugin`). Reference `naleo/audiobookshelf.koplugin` for: `_meta.lua` template, `socketutil` + Bearer auth pattern, ABS endpoint URL shapes, `MultiInputDialog` / `LuaSettings` conventions.
2. Config auto-create (`server`, `token`, `download_dir`, `preferred_format`, `log_level`)
3. Settings UI — all five fields editable in-app
4. API client (`api.lua`) — all 8 endpoints with retry-with-backoff. HTTP pattern referenced from naleo:
   - `getLibraries()`, `getLibraryItems()`, `getItemDetails()`, `downloadFile()`
   - `getProgress()`, `updateProgress()`, `getItemsInProgress()`
   - Remove ebook filters from browse/search
   - Add JSON body support for PATCH (naleo only does GET)
5. Error handling foundation — `pcall` + `socketutil` timeouts, retry-with-backoff utility, error dialog helper
6. Manifest module (`manifest.lua`) — read/write, CRUD for book entries

**Testable outcome:** Plugin loads, shows settings dialog, can call ABS API and get real data back.

### Phase 2: Browse and display (no hardware)

7. Dashboard widget — 4 sections (resume/stubbed, downloaded/empty state, library entry, settings entry)
8. Library browser — KOReader Menu widget with search, sort cycle, client-side pagination, cover thumbnails, duration formatting. Structure pattern referenced from naleo's browser.
9. Adaptive detail view — single widget, different actions based on download state:
   - Not downloaded: metadata, audio file list, ebook/PDF file list, download buttons
   - Downloaded: same metadata + play button, delete button, progress badge
10. Format preference filtering in detail view (highlight which files matching preferred format)
11. Chapter list display in detail view (from `media.chapters`)

**Testable outcome:** Browse ABS library, see audiobooks with durations, tap detail view, see audio+PDF files listed.

### Phase 3: Download pipeline (no hardware)

12. Background download with progress bar widget (coroutine + chunked reads)
13. Format preference filter on download (m4b → mp3 → all)
14. File-level tracking (complete/partial/pending per file in manifest)
15. HTTP Range resume for partial files (+ fallback to full re-download)
16. Re-download prompt ("Already downloaded. Overwrite?")
17. First-download folder picker → save as `download_dir`
18. Delete action — removes files + manifest entry atomically
19. PDF/ebook download → open in ReaderUI post-download
20. File/folder sanitization (spaces→underscores, strip special chars, truncate)
21. Folder naming: `{author}_{title}/`
22. Incomplete download scan on startup (manifest vs actual file sizes)

**Testable outcome:** Download an M4B, see progress, verify correct folder on disk. Disconnect WiFi mid-download, reconnect, resume.

### Phase 4: Playback (**hardware required**)

23. Minimal FFI test — `ffi.C.PlayFile()` on a test file, verify it works from KOReader context
24. Determine position units (seconds? ms? samples?)
25. Verify KOReader stays responsive while native player is active
26. `player.lua` — FFI wrapper: `play(path)`, `pause()`, `resume()`, `getPosition()`, `setPosition(pos)`, `getDuration()`, `stop()`, `close()`
27. Playlist support via `LoadPlaylist()` / `PlayTrack(n)` (or fall back to single-file)
28. Global position ↔ (track index, offset) conversion functions
29. Chapter navigation — current chapter lookup by position, next/prev chapter, seek-to-chapter
30. Wire play/resume buttons in dashboard and detail view to player

**Testable outcome:** Tap play on a downloaded audiobook, hear audio, see position updating. Chapter seeking works.

### Phase 5: Sync (needs Phase 4, push/pull testable manually)

31. `sync.lua` — `pullProgress(item_id)`, `pushProgress(item_id)`
32. Conflict resolution — furthest position wins + isFinished guard + confirmation dialog
33. "Sync now" action in settings
34. Pull on playback start (before playing, update manifest from server)
35. Offline behavior — silently skip, save locally, show disabled/greyed state

**Testable outcome:** Listen on PocketBook, hit sync, see position update in ABS web UI. Listen on phone, open PocketBook, resume at correct spot.

### Phase 6: Polish

36. 60-second auto-sync timer during playback
37. Sync on plugin exit / KOReader suspend
38. "Resume last book" dashboard button (was stubbed in Phase 2)
39. Offline-aware UI — grey out library/sync when no connectivity
40. Disk-space check before download
41. Current chapter name display during playback + next/prev chapter controls
42. Incomplete download scan on startup (manifest vs actual file sizes)
43. Edge case hardening (manifest corruption recovery, empty library, etc.)

**Testable outcome:** Full round-trip: phone listen → PocketBook auto-resume → auto-sync back → phone sees updated position. Chapter seeking works. Incomplete downloads detected and resumable on restart.


## The hard part: playback + position capture — SOLVED

### audiobook.koplugin is NOT what it seems

The Perplexity session referenced audiobook.koplugin (stradichenko) as a potential playback layer. After reading the full source code, this is a **TTS (text-to-speech) plugin**, not an audio file player. It:

- Synthesizes ebook text to WAV using espeak-ng or Piper
- Plays the synthesized WAV with word-by-word highlighting
- Has nothing to do with playing pre-existing M4B/MP3 audiobook files

Its audio output chain on PocketBook uses ALSA (`tts_sm` PCM device via a bundled `wav-play` binary). The Bluetooth path uses GStreamer with a persistent FIFO pipeline. None of this is useful for playing M4B files.

**This plugin is a dead end for your use case. Do not try to integrate with it.**

### The real answer: PocketBook's inkview API

The PocketBook SDK's `inkview.h` header exposes a **complete built-in audio player API**:

```c
void OpenPlayer();
void ClosePlayer();
void PlayFile(const char *filename);    // ← start playback of M4B/MP3/OGG
void LoadPlaylist(char **pl);
char **GetPlaylist();
void PlayTrack(int n);
void PreviousTrack();
void NextTrack();
int GetCurrentTrack();
int GetTrackSize();                     // ← total duration
void SetTrackPosition(int pos);         // ← seek
int GetTrackPosition();                 // ← current position (!)
void SetPlayerState(int state);
int GetPlayerState();                   // ← playing/paused/stopped
void SetPlayerMode(int mode);
int GetPlayerMode();
void TogglePlaying();
void SetVolume(int n);
int GetVolume();
```

And KOReader on PocketBook **already loads `libinkview` via LuaJIT FFI** at startup. The KOReader logs show `ffi.load: inkview` during initialization. This means a KOReader plugin can call these functions directly through FFI without any external binary or library.

### What this means for your plugin

The player.lua module becomes trivially simple:

```lua
local ffi = require("ffi")

-- Declare the inkview audio functions we need
ffi.cdef[[
    void PlayFile(const char *filename);
    int GetTrackPosition();
    int GetTrackSize();
    void SetTrackPosition(int pos);
    int GetPlayerState();
    void TogglePlaying();
    void ClosePlayer();
]]

-- Play an M4B file
ffi.C.PlayFile("/mnt/ext1/audiobooks/my_book.m4b")

-- Read current position (for sync)
local pos = ffi.C.GetTrackPosition()
local total = ffi.C.GetTrackSize()

-- Seek to a position (for resume)
ffi.C.SetTrackPosition(saved_position)
```

There are unknowns about the exact units (`GetTrackPosition` probably returns milliseconds or seconds — needs testing), and whether the FFI declarations need to go through a loaded inkview lib handle rather than `ffi.C`. But the API surface is exactly what you need: play, pause, seek, get position, get duration.

### What needs testing on hardware

Before building the full plugin, verify these on the actual PocketBook Era:

1. `PlayFile("/path/to/test.m4b")` — does it launch the native player?
2. `GetTrackPosition()` — what units does it return? ms? seconds? samples?
3. Does KOReader's UI remain responsive while the native player is active, or does it take over the screen?
4. Can you call `GetTrackPosition()` while the native player is in the background?
5. Does `SetTrackPosition()` work for seeking within an M4B file (which has chapters)?

If tests 1-4 work, your entire playback + position capture problem is solved with ~30 lines of Lua. This is drastically simpler than anything the Perplexity session anticipated.


## What I'd do differently from the Perplexity skeleton

| Perplexity skeleton | My recommendation | Why |
|---|---|---|
| Starts from scratch with hello plugin | Build from scratch, reference naleo's patterns | ~140 lines of reusable patterns (socketutil, Bearer auth, _meta.lua, MultiInputDialog, LuaSettings) vs ~2080 lines new/heavily-rewritten (~93% new code). Forking adds overhead without benefit. See ADR-0006. |
| Uses `socket.http` for HTTP | Use naleo's exact pattern: `socket.http` + `socketutil` + `pcall` | naleo's code wraps every request in `socketutil:set_timeout()` / `reset_timeout()` + `pcall`. The Perplexity skeleton skipped timeout management entirely |
| Uses `MultiInputDialog` for settings | Keep naleo's approach: config file + in-app settings dialog | naleo actually does both — a config file for initial setup AND an in-app `MultiInputDialog` for editing. Best of both worlds |
| Models the full ABS session lifecycle | Use `PATCH /api/me/progress` only | One call vs. open/sync/close session — much simpler |
| Tight coupling to audiobook.koplugin | Don't use it at all — it's a TTS engine | It synthesizes speech from text. It does NOT play M4B files. Wrong tool entirely |
| All modules in plugin root | Subdirectory for modules | Follows naleo's cleaner structure |
| Progress update via query string | Progress update via JSON body | The ABS API expects a JSON PATCH body |


## Risks and mitigations

**inkview audio API might not work from KOReader context.** The FFI declarations should work since KOReader already loads inkview, but the native player might take over the screen or conflict with KOReader's event loop. Mitigation: test with a minimal plugin first — just `PlayFile()` + `GetTrackPosition()`.

**Position units are undocumented.** The SDK header doesn't say what unit `GetTrackPosition()` returns. Mitigation: call it during playback and compare to known file duration. One test run resolves this permanently.

**ABS API may change.** Mitigation: wrap all API calls in client.lua with defensive error handling. Only use 6 endpoints. Pin to endpoints that exist in your server version.

**Sync conflicts between devices.** Mitigation: for v1, use "furthest position wins" as the merge policy. It's wrong sometimes (if you re-listen a section) but safe for the common case.

**Large M4B files fill device storage.** Mitigation: show file size before download. Add a "delete local file" action. Since your library is single-file M4B, you'll be downloading whole books — so storage management matters.


## Time estimate

With the inkview API discovery, the timeline shifts significantly compared to the Perplexity session's estimate:

- Phase 1 (browse + download): 1 weekend, high confidence
- Phase 2 (playback via inkview FFI): 1 evening if it works; 1-2 weekends if there are complications
- Phase 3 (manual sync): 1 weekend, high confidence
- Phase 4 (auto sync + resume): 1 weekend, high confidence (because `GetTrackPosition()` gives you position capture for free)

Total: 3-4 weekends for a usable personal plugin. The variance is much smaller now that the playback mechanism is identified.


## Open questions to resolve before coding

1. ~~Do you already have the PocketBook Era?~~ → No, not yet
2. ~~Does naleo's plugin work on your device?~~ → Can't test yet
3. ~~Can you play an M4B file from the PocketBook Era's native player?~~ → Yes per research
4. ~~Does audiobook.koplugin work on the Era?~~ → **Irrelevant** — it's a TTS plugin, not an M4B player
5. ~~Is your ABS library primarily single-file M4B?~~ → Yes, all single-file M4B

### New questions (post-research)

6. **Does `ffi.C.PlayFile()` work from a KOReader plugin on PocketBook?** Or do you need to call through a loaded inkview handle? KOReader's FFI binding may already alias this.
7. **What does `GetTrackPosition()` return?** Milliseconds, seconds, or sample offset? A single test call answers this.
8. **Does the PocketBook native player run in the background while KOReader stays active?** Or does it take over the screen? This determines whether you can show your plugin UI while audio plays.
9. **Does KOReader on the Era use the inkview input mode or raw input mode?** (The raw_input PR #6791 suggests PB740-2 uses raw input; the Era is a PB700 — likely still inkview mode, which is actually better for calling inkview audio APIs.)

