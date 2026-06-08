# Changelog

All notable changes to this project will be documented in this file. The format is based on [Common Changelog](https://common-changelog.org) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### feat

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

### test

- **config:** 12 unit tests for defaults, read/write round-trip, validation, first-run detection
- **logger:** 7 unit tests for level filtering, delegation, and suppression
- **error-handler:** 20 unit tests for error mapping, HTTP status codes, and nil-safety
- **manifest:** 7 unit tests for CRUD operations, file status, and position tracking
