# Changelog

All notable changes to this project will be documented in this file. The format is based on [Common Changelog](https://common-changelog.org) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### feat
- **download-progress:** add download progress widget with file count, percentage, ETA, and cancel button
- **download:** add free space check before downloads using `df` command
- **download:** add coroutine-based chunked download (`start_chunked_download`) using raw socket I/O via `chunked_http` module that yields to KOReader event loop every 32KB, enabling progress updates and cancel during large file transfers
- **download:** add ebook download button in book detail view with `ebook_only` flag
- **api:** add `downloadFile` endpoint with Range header support for resuming partial downloads

### fix
- **download:** fix cancel button hanging emulator until download completes — `scheduleIn(0, pump)` made each pump "due now" so UIManager's task drain loop never yielded to input event processing; changed to `scheduleIn(0.05)` (50ms) so cancel taps are dispatched between chunks
- **book-detail:** fix ebook file detection — ABS API returns `media.ebookFile` (singular object), not `ebookFiles` (plural array); convert to internal format with fallback
- **downloader:** fix `get_ebook_files` to check `media.ebookFile` first (ABS format), falling back to `media.ebooks`
- **download:** fix `attempt to yield across C-call boundary` crash — `socket.http.request` wraps everything in `socket.protect(pcall)`, making `coroutine.yield()` inside ltn12 sinks impossible; created raw socket `chunked_http` module that reads body chunks via `sock:receive()` and yields between reads in pure Lua context, bypassing C-boundary entirely
- **library-browser:** wire free space check to show InfoMessage when insufficient disk space
- **library-browser:** wire download/delete callbacks through navigator to book detail view
- **manifest:** fix `init()` discarding in-memory download state by re-reading from disk — make init idempotent (no-op after first call), add `flush()` to all mutating functions so changes persist
- **book-detail:** fix checkerboard cover after download — verify `cover.jpg` exists on disk before using it, fall through to cached cover or placeholder

### fix

- **nav:** defer closing previous widget until new one is ready — eliminate flash of KOReader file browser during async screen transitions (e.g., library → book detail)
- **book-detail:** call `nav.pop()` when async `detail.prepare()` fails so navigator restores library browser instead of leaving user on blank screen
- **nav:** prevent state corruption when `browser.show()` fails inside `nav.push()` — show_fn returning nil now triggers automatic rollback to previous screen instead of leaving navigator with a nil widget and wrong screen name
- **api:** guard `request_with_retry` on `transport` nil instead of `socket_http_ok` — prevent nil dereference when `api.init()` was never called
- **dashboard:** log warning when `prepare()` fails instead of silently discarding the error
- **library-browser:** remove stray `print()` that appeared in production logs on every module load
- **book-detail:** return widget from `detail.show()` so navigator can track and close the detail screen; fix widget leak on every Back press
- **nav:** prevent state corruption when `browser.show()` fails inside `nav.push()` — show_fn returning nil now triggers automatic rollback to previous screen instead of leaving navigator with a nil widget and wrong screen name
- **api:** guard `request_with_retry` on `transport` nil instead of `socket_http_ok` — prevent nil dereference when `api.init()` was never called
- **dashboard:** log warning when `prepare()` fails instead of silently discarding the error
- **library-browser:** remove stray `print()` that appeared in production logs on every module load

- **library-browser:** expose search feature with magnifying glass icon button, InputDialog, and `browser.search()` API; show active query text next to icon
- **dashboard:** extract `prepare()` function separating data fetching from widget rendering; add 4 tests for pure-data paths
- **library-browser:** extract `browser.prepare()` for data/render split; add 4 tests covering config/api/network error paths
- **book-detail:** extract `detail.prepare()` with API→manifest→basic fallback chain; add 3 tests for success, fallback, and error
- **dashboard:** grey out Browse Library button when offline (last fetch failed) or API not configured; show reason text beneath button; add `wasLastFetchSuccessful()` tri-state to library_store
- **book-detail:** add offline fallback path — manifest data for downloaded books, WiFi message for undownloaded; add 9 unit tests covering merge, manifest fallback, and error paths

### fix

- **library-browser:** fix Lua closure scoping in onSearch — split `local x = expr` into `local x; x = expr` so closures in button callbacks can capture the upvalue
- **nav:** fix double-close in LibraryBrowserView:onClose() and BookDetailView:onClose() — both called UIManager:close(self) then nav.pop() which also closes the widget; let nav.pop() own the close when navigator is active
- **nav:** fix stale navigator reference after LibraryBrowserView:_refresh() recreates widget — add nav._setCurrent() helper so pop() targets the live widget instead of the closed one

- **settings:** guard onSaveSettings against nil fields on shutdown — prevents crash when closing emulator or KOReader broadcasts CloseWidget without dialog arguments

- **library-browser:** DPI-scale cover thumbnails, compute dynamic page size from screen dimensions, fetch all covers upfront with persistent cache, add clear-cache button in settings

### fix

- **library:** correct title/author extraction to read from nested media.metadata instead of flat fields; fixes all items showing Unknown Title
- **cover-cache:** fix api.getCover method call (colon to dot), dual-path lfs loading for KOReader, and recursive mkdir for cache directory creation
- **cover-cache:** replace streaming file_sink with ltn12.sink.table bulk write to prevent truncated cover files
- **library-browser:** fix scrolling (adopt cropping_widget+show_parent pattern) and pagination (Prev/Next nav bar)

- **cover-cache:** add cover art fetch and local JPEG cache module with hasCachedCover/fetchAndCache API
- **library-store:** add data layer with client-side search, 6 sort modes, and pagination (25/page) over cached ABS items
- **library-browser:** add fullscreen scrollable book list with cover thumbnails, sort cycling, search dialog, and load-more pagination
- **book-detail:** add fullscreen book detail view with cover art, metadata, audio/ebook files with preferred format highlighting, tappable chapter list, download status badge, and offline manifest fallback
- **dashboard:** wire Browse Library button to library browser → book detail navigation flow
- **api:** fix api.init() never being called — add initialization at plugin startup and after settings save
- **plugin:** register with KOReader menu system as "ABS Audio" with dispatcher actions

- **config:** add LuaSettings-backed config manager with typed access, defaults, and URL validation
- **settings:** add MultiInputDialog with 5 fields (server URL, API token, download dir, preferred format, log level)
- **settings:** validate credentials against ABS server via `GET /api/libraries` on save
- **first-run:** auto-open settings dialog when no config file exists
- **logger:** add configurable verbosity wrapper (verbose/info/warn) with `[ABS]` prefix
- **error-handler:** add centralized error-to-dialog mapping that never crashes KOReader
- **dashboard:** add fullscreen overlay with 4 sections (Resume, Downloaded, Browse, Settings)
- **manifest:** add CRUD module for per-book state tracking with LuaSettings persistence
- **api:** add Audiobookshelf API client with 9 endpoints, Bearer auth, retry with backoff
- **error-handler:** add HTTP status code mapping and from_api_error() for API errors
- **dashboard:** wire Settings button to plugin config dialog via callbacks
- **dashboard:** add Sync Now and Export Diagnostics stub buttons in Settings section

### test

- **config:** 12 unit tests for defaults, read/write round-trip, validation, first-run detection
- **logger:** 7 unit tests for level filtering, delegation, and suppression
- **error-handler:** 20 unit tests for error mapping, HTTP status codes, and nil-safety
- **manifest:** 7 unit tests for CRUD operations, file status, and position tracking
- **cover-cache:** 6 unit tests for init, getCoverPath, hasCachedCover, fetchAndCache with mock file system
- **library-store:** 20 unit tests for fetchAll, pagination, search (title/author), 6 sort modes, getCurrentSort/setSort
