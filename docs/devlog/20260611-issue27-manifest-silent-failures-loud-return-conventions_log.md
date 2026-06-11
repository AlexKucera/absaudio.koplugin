# Issue #27: Manifest Silent Failures Loud + Return Conventions

**Date:** 2026-06-11
**Type:** issue
**Issue:** #27
**Status:** complete

## Goal

Two hygiene improvements:
1. Make manifest mutation functions (`updateBook`, `updateFileStatus`, `updatePosition`) emit `abs_logger.warn()` instead of silently no-oping on nil/wrong ID.
2. Document return value conventions in every module header so callers know what to expect.

## Changes

### manifest.lua — Loud failures

- Added `local abs_logger = require("abs_logger")` import.
- **`updateBook`**: Now returns `true` on success, `false` + `abs_logger.warn()` when entry not found (nil or nonexistent ID).
- **`updateFileStatus`**: Returns `true` on success; `false` + warn for two miss cases: book not found, or file not found within existing book. Also fixed a subtle bug where the function always called `saveSetting`/`flush()` even when no file matched — now only flushes when a file is actually updated.
- **`updatePosition`**: Returns `true` on success, `false` + warn when entry not found.

### All 15 modules — Return convention documentation

Added one-line `Return convention:` comment to each module header:

| Module | Convention |
|--------|-----------|
| manifest.lua | `(boolean)` mutations on success/miss; direct value for queries |
| api.lua | `(boolean, result\|error)` ok-pattern for all endpoints |
| config.lua | Direct value (no boolean wrapper) — simple accessor |
| abs_logger.lua | Void for log functions; direct value for accessors |
| downloader.lua | Mixed — direct value for sanitize; `(boolean, string)` for execute/prepare |
| cover_cache.lua | `(boolean, path_or_nil)` ok-pattern |
| library_store.lua | Structured table for getItems; `(boolean, count)` for fetchAll |
| fs_helpers.lua | Boolean for deletes; direct value for get_file_size |
| widget_helpers.lua | Direct value — pure utility functions |
| chunked_http.lua | `(boolean, status_code\|error_string)` ok-pattern |
| navigator.lua | Void for push/pop/reset; boolean for async show_fn |
| error_handler.lua | Void for show(); direct value for helpers |
| main.lua | Void — all side-effecting |
| download_progress.lua | Void for show/close; direct value for format |

## Test Summary

### New tests (6) — spec/test_manifest.lua Slice 5

1. `updateBook warns when given nonexistent ID` — verifies 1 warning emitted, mentions the ID
2. `updateBook warns when given nil ID` — verifies 1 warning emitted for nil
3. `updateFileStatus warns when book not found` — verifies 1 warning for nonexistent book
4. `updateFileStatus warns when file not found in book` — verifies 1 warning for missing filename
5. `updatePosition warns when book not found` — verifies 1 warning for nonexistent ID
6. `mutation functions do NOT warn for valid IDs` — regression guard: valid ops produce zero warnings

### Test infrastructure change

Changed logger stub from no-op to recording stub (`recorded_warnings` table) so tests can assert on warning emission.

## Results

- **Before:** 344 passing tests (20 manifest)
- **After:** 354 passing tests (26 manifest, +6 new)
- **Acceptance criteria met:** 5/5 ✅

## Decisions & Rationale

- Chose `abs_logger.warn()` over `error()` because these are not fatal — callers may legitimately attempt updates for items that haven't been added yet (e.g., during sync reconciliation). A warning makes the problem visible without crashing.
- Return `false` on miss gives callers an optional way to check programmatically, but doesn't break any existing code that ignored the return value (Lua discards unused return values silently).
- Fixed subtle `updateFileStatus` bug where it always flushed settings even when no file was found — this was a latent unnecessary-write bug exposed by adding the found-tracking variable.

## Gotchas

- Logger stub in test_manifest.lua needed to be changed from no-op to recording to capture warnings. This required updating the stub before `require("manifest")` since manifest now calls `require("abs_logger")` at module load time.
- `widget_helpers.lua` edit triggered a "changed 141 lines" warning due to the em dash (—) character matching issue with the edit tool's fuzzy matcher. Verified no unintended changes.

## Open Items

None — this issue is complete. Future work (not in scope): adopt a single return convention across all modules (documented as a larger effort in #27 description).

## Files Modified

- `manifest.lua` — added abs_logger import, warn+return-false on miss for 3 functions
- `api.lua` — return convention comment
- `config.lua` — return convention comment
- `abs_logger.lua` — return convention comment
- `absaudio/downloader.lua` — return convention comment
- `absaudio/cover_cache.lua` — return convention comment
- `absaudio/library_store.lua` — return convention comment
- `absaudio/fs_helpers.lua` — return convention comment
- `absaudio/widget_helpers.lua` — return convention comment
- `absaudio/chunked_http.lua` — return convention comment
- `absaudio/navigator.lua` — return convention comment
- `error_handler.lua` — return convention comment
- `main.lua` — return convention comment
- `absaudio/download_progress.lua` — return convention comment
- `spec/test_manifest.lua` — 6 new tests + recording logger stub
