# Changelog

All notable changes to this project will be documented in this file. The format is based on [Common Changelog](https://common-changelog.org) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### feat

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
