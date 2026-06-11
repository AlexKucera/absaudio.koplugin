# Issue #24 — pcall-guard abs_logger bare require(logger) for crash prevention

> **Date:** 2026-06-11
> **Type:** issue
> **Reference:** [Issue #24](https://github.com/AlexKucera/absaudio.koplugin/issues/24)

## Goal

Replace bare `require("logger")` in `abs_logger.lua` with `pcall(require, "logger")` and a print-based fallback. `abs_logger` is required by 12 files across the plugin — if KOReader's logger module is missing, the entire plugin crashes on startup before any other module's pcall guard gets a chance to degrade gracefully.

## What Was Done

### Changed `abs_logger.lua` line 12 (1 line → 10 lines)

**Before:**
```lua
local koreader_logger = require("logger")
```

**After:**
```lua
-- pcall-guard: KOReader's logger may be absent (test env, or future KOReader changes)
local koreader_ok, koreader_logger = pcall(require, "logger")
if not koreader_ok then
    -- Fallback: print-based logger with [ABS] prefix
    koreader_logger = {
        dbg = function(msg) print(tostring(msg)) end,
        info = function(msg) print(tostring(msg)) end,
        warn = function(msg) print(tostring(msg)) end,
    }
end
```

The `[ABS]` prefix is already applied by `abs_logger`'s own wrapper (`PREFIX = "[ABS] "` at line 33), so the fallback only needs to provide `dbg`/`info`/`warn` methods that output to `print()`.

### Added 3 new tests to `spec/test_logger.lua`

| Test | What it verifies |
|------|-----------------|
| `loads successfully when logger module is absent` | `pcall(require, "abs_logger")` returns `(true, table)` with `info`/`warn`/`verbose` methods when `package.loaded["logger"] = nil` |
| `fallback logger outputs [ABS] prefixed messages via print` | Captures `print()` output, verifies `[ABS]` prefix appears in fallback log messages |
| `fallback logger respects level filtering` | Setting level to `warn` suppresses verbose/info fallback output, only warn prints |

## Decisions & Rationale

- **Fallback is print-based, not silent.** When running outside KOReader (e.g., test environment or if logger is ever removed), diagnostic output is still visible via stdout/stderr. This matches the behavior of `dashboard_widget.lua` which falls back to `print()` for missing modules.
- **No `_G.logger` fallback attempted.** Unlike `lfs` (which KOReader injects as a global), `logger` is a regular Lua module — if `require` fails, it won't be available as a global either.
- **Fallback provides all 3 methods.** Even though the fallback only needs `dbg`/`info`/`warn`, providing all three keeps the contract identical regardless of which code path runs.

## Gotchas & Fixes

- **Test bug: `string.find` with `plain=true` treats `%[ABS%]` literally.** First attempt used `string.find(msg, "%[ABS%]", 1, true)` which searches for the literal string `%[ABS%]`, not the pattern `[ABS]`. Fixed to `string.find(msg, "[ABS]", 1, true)` for plain-text search.

## Acceptance Criteria Status

| # | Criteria | Status |
|---|----------|--------|
| 1 | `abs_logger.lua` loads `logger` via `pcall(require, "logger")` with graceful fallback | ✅ |
| 2 | Fallback logger outputs `[ABS]` prefixed messages via `print()` when KOReader logger unavailable | ✅ |
| 3 | Plugin loads successfully even when `logger` module is absent | ✅ |
| 4 | All existing logger tests pass (7 → now 10) | ✅ |
| 5 | New test: verify abs_logger works with mocked-out logger module | ✅ (3 new tests) |

## Test Results

```
10 passed, 0 failed (spec/test_logger.lua)
344 total tests pass across all 17 test files
```

## Next Steps

None — this issue is complete. The change is minimal, well-tested, and follows the established `pcall(require, ...)` pattern used consistently across all other plugin modules.
