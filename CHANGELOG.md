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
- **dashboard:** add placeholder shell with 4 sections (Resume, Downloaded, Browse, Settings)

### test

- **config:** 12 unit tests for defaults, read/write round-trip, validation, first-run detection
- **logger:** 7 unit tests for level filtering, delegation, and suppression
- **error-handler:** 6 unit tests for error mapping and nil-safety
- All 25 tests pass under both `lua` and `luajit`
