# Issue #28 — Unify HTTP Error Classification (api ↔ error_handler)

> **Date:** 2026-06-11
> **Type:** issue
> **Reference:** [Issue #28](https://github.com/AlexKucera/absaudio.koplugin/issues/28)

## Goal

Eliminate duplicate HTTP status code → error type classification logic between `api.classify_http_error()` (local function, lines 76–87) and `error_handler.classify_http_status()` (public function, lines 43–55). Make `error_handler` the canonical source and have `api` delegate to it, keeping only API-specific overrides locally.

## What Was Done

### Analyzed Both Classification Functions

**`api.classify_http_error(status_code)`** — local function returning only the error type string:
| Status | Type |
|--------|------|
| 401, 403 | `"auth"` |
| 404 | `"not_found"` |
| ≥500 | `"server"` |
| ≥400 (other) | `"client"` ← **API-specific** |
| else | `"unknown"` |

**`error_handler.classify_http_status(status_code)`** — public function returning `(type, message)`:
| Status | Type | Message source |
|--------|------|---------------|
| 401, 403 | `"auth"` | HTTP_ERROR_MAP |
| 404 | `"not_found"` | HTTP_ERROR_MAP |
| 429 | `"api"` | HTTP_ERROR_MAP |
| ≥500 | `"server"` | fallback |
| ≥400 (other) | `"api"` | fallback |
| else | `"unknown"` | fallback |

**Key difference**: Generic 4xx codes map to `"client"` in api but `"api"` in error_handler. This is an API-specific classification that must remain local.

### Refactored `classify_http_error` to Delegate

Added lazy-loaded `error_handler` import with pcall guard in `api.lua`:

```lua
local _error_handler_ok, _error_handler = pcall(require, "error_handler")
```

Refactored `classify_http_error()`:
1. When `error_handler` is available: calls `error_handler.classify_http_status(status_code)` and returns the type
2. Applies API-specific override: unmapped 4xx codes return `"client"` instead of `"api"`
3. Falls back to inline logic when `error_handler` is unavailable (graceful degradation)

### Added 6 Agreement Tests

New test section in `spec/test_api.lua`: "api ↔ error_handler HTTP classification agreement"

Verifies that for status codes 401, 403, 404, 500, 502, 503, the error type returned by API calls matches what `error_handler.classify_http_status()` returns.

Required adding KOReader stubs (`ui/widget/infomessage`, `ui/uimanager`, `gettext`) to test_api.lua before requiring error_handler.

## Acceptance Criteria Status

| # | Criteria | Status |
|---|----------|--------|
| 1 | `api.classify_http_error()` delegates to `error_handler.classify_http_status()` for shared cases | ✅ Done |
| 2 | API-specific classifications remain local to api.lua | ✅ Done (`"client"` override for generic 4xx) |
| 3 | All existing api tests pass | ✅ 26→32 pass (+6 new agreement tests) |
| 4 | All existing error_handler tests pass | ✅ 20 pass |
| 5 | New test verifying agreement on common status codes | ✅ 6 tests (401, 403, 404, 500, 502, 503) |

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Use `pcall(require, "error_handler")` with lazy load | Matches existing pattern for all optional module dependencies; graceful degradation if error_handler unavailable (e.g., in minimal test environments without KOReader UI stubs) |
| Keep `"client"` override as local exception | This IS the API-specific behavior — error_handler correctly uses `"api"` for its domain, but api.lua's internal classification distinguishes client errors (4xx) from server errors (5xx) |
| Preserve fallback code path | If error_handler can't load (missing KOReader UI deps), classify_http_error still works with identical behavior to before the refactor |
| Agreement tests use observable API behavior | Since `classify_http_error` is local, tests verify via actual API call error responses compared against `error_handler.classify_http_status()` direct calls |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| Agreement tests inserted after Summary block never executed | Edit anchor landed inside `if #errors > 0 then` / `os.exit(1)` block | Moved test section before `-- Summary` header |
| `require("error_handler")` crashed with `module 'ui/widget/infomessage' not found` | test_api.lua didn't stub KOReader UI dependencies that error_handler requires | Added `package.loaded` stubs for `ui/widget/infomessage`, `ui/uimanager`, `gettext` before the require (matching pattern from test_error_handler.lua) |

## Files Changed

| File | Change Summary |
|------|---------------|
| `api.lua` | +14 net lines. Added pcall-guarded error_handler import; refactored `classify_http_error()` to delegate to `error_handler.classify_http_status()` with API-specific `"client"` override; preserved fallback path |
| `spec/test_api.lua` | +44 net lines. Added KOReader stubs for error_handler dependency; added 6 agreement tests verifying api ↔ error_handler classification consistency on common status codes |

## Metrics

| Metric | Before | After | Delta |
|--------|--------|-------|-------|
| api.lua total lines | 483 | 497 | **+14** |
| test_api.lua tests | 26 | 32 | **+6** |
| test_error_handler tests | 20 | 20 | — |
| Total test suite (passing) | ~347 | ~353 | **+6** |
| GitNexus index nodes | 695 | 721 | **+26** |

## Next Steps

- Consider extracting `classify_http_error` to a public `api.classify_http_error()` if other modules need direct access to HTTP classification
- The `"client"` vs `"api"` naming divergence for generic 4xx could be aligned in a future pass if consumers don't depend on the literal string `"client"`
