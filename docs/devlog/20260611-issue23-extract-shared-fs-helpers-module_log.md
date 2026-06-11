# Issue #23 — Extract Shared fs_helpers Module

> **Date:** 2026-06-11
> **Type:** issue
> **Reference:** [Issue #23](https://github.com/AlexKucera/absaudio.koplugin/issues/23)

## Goal

Extract duplicated filesystem utility functions into a shared `absaudio/fs_helpers.lua` module. After Issue #26 removed one copy-paste site (library_browser's dead `_onDownloadBook`), two sites remained with inline `mkdir -p` logic: `cover_cache.fetchAndCache()` and `book_detail._onDownloadBook()`. Both become one-liners calling `fs_helpers.mkdir_p()`.

## What Was Done

### Created `absaudio/fs_helpers.lua`

New module with 4 shared filesystem utilities:

| Function | Purpose |
|----------|---------|
| `mkdir_p(path)` | Recursive directory creation (like `mkdir -p`). Splits path, creates each missing component. Handles absolute/relative paths, idempotent (skips existing dirs), validates nil/empty input |
| `get_file_size(path)` | Safe `lfs.attributes` size lookup. Returns nil for missing files or nil input |
| `delete_file(path)` | `os.remove` wrapper with nil guard |
| `delete_dir(path)` | `lfs.rmdir` wrapper with lfs availability guard |

The module uses the standard KOReader lfs loading pattern: `pcall(require, "lfs")` then fallback to `_G.lfs`.

### Replaced Inline mkdir in `cover_cache.fetchAndCache()`

**Before** (26 lines of inline mkdir-p logic):
```lua
-- Split path into parts, iterate creating each component,
-- check lfs.attributes, call lfs.mkdir, handle errors...
```

**After** (6 lines):
```lua
if has_fs_helpers and cache_dir then
    local mkdir_ok, mkdir_err = fs_helpers.mkdir_p(cache_dir)
    if not mkdir_ok then return false, mkdir_err end
elseif not cache_dir then
    return false, { type = "io", message = "Cache directory not initialized" }
end
```

### Replaced Inline mkdir in `book_detail._onDownloadBook()`

**Before** (10 lines of inline mkdir in deps.fs table):
```lua
mkdir = function(path)
    local parts = {}
    for part in path:gmatch("[^/]+") do
        table.insert(parts, part)
    end
    local current = ""
    for _, part in ipairs(parts) do
        current = current .. "/" .. part
        if not lfs_mod.attributes(current) then
            lfs_mod.mkdir(current)
        end
    end
end,
```

**After** (4 lines):
```lua
mkdir = function(path)
    if has_fs_helpers then
        fs_helpers.mkdir_p(path)
    end
end,
```

### Created `spec/test_fs_helpers.lua`

12 tests covering all 4 public functions:

| Test | What it verifies |
|------|-----------------|
| `mkdir_p creates a single-level directory` | Basic success case |
| `mkdir_p is idempotent when directory already exists` | No redundant mkdir calls |
| `mkdir_p creates nested directories recursively` | Full path `/a/b/c/d` all created |
| `mkdir_p returns error for nil path` | Input validation |
| `mkdir_p returns error for empty string` | Input validation |
| `get_file_size returns size for existing file` | Normal lookup |
| `get_file_size returns nil for non-existent file` | Missing file handling |
| `get_file_size returns nil for nil input` | Input guard |
| `delete_file calls os.remove and returns true` | Delegation + return value |
| `delete_file returns false for nil path` | Input guard |
| `delete_dir calls lfs.rmdir and returns true` | Delegation + return value |
| `delete_dir returns false for nil path` | Input guard |

## Acceptance Criteria Status

| # | Criteria | Status |
|---|----------|--------|
| 1 | Create `absaudio/fs_helpers.lua` with mkdir_p, get_file_size, delete_file, delete_dir | ✅ Done |
| 2 | Replace inline mkdir in cover_cache.fetchAndCache with fs_helpers.mkdir_p() | ✅ Done (−20 net lines) |
| 3 | Replace inline mkdir in book_detail._onDownloadBook with fs_helpers.mkdir_p() | ✅ Done (−8 net lines) |
| 4 | Tests for fs_helpers: normal creation, path exists, nested paths, nil input, error handling | ✅ 12 tests |
| 5 | All existing tests pass (cover_cache + book_detail especially) | ✅ 341 total pass |

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Use `pcall(require)` pattern for fs_helpers in consumers | Matches existing pattern used for all optional module dependencies (api, manifest, downloader, etc.) — graceful degradation if module missing |
| Keep both `lfs` loading strategies in fs_helpers itself | KOReader provides lfs as either require-able module or _G global; fs_helpers must work in both contexts since it's a low-level utility |
| Include all 4 helpers even though only mkdir_p is used now | The module is a shared utility bucket; get_file_size/delete_file/delete_dir are already copy-pasted across modules and can be migrated incrementally |
| Mock lfs fully in test file rather than using test_helper stubs | fs_helpers is a pure filesystem module — its tests need full control over lfs behavior (attributes returning modes/sizes, mkdir tracking, rmdir tracking). Other test files mock lfs minimally for their specific needs |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| First test run failed: `module 'abs_logger' not found` | fs_helpers requires abs_logger which requires logger; neither was mocked before `require("absaudio/fs_helpers")` | Added `package.loaded["logger"]` and `package.loaded["abs_logger"]` mocks before the require, matching pattern from other test files |
| cover_cache had separate `lfs_ok` guard around old mkdir block | Old code checked `if lfs_ok and cache_dir then` before the inline block; new code needs equivalent guard via `has_fs_helpers` | Used `has_fs_helpers` (from pcall require) as the availability check |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/fs_helpers.lua` | **New file** — 93 lines, 4 exported functions |
| `spec/test_fs_helpers.lua` | **New file** — 249 lines, 12 tests |
| `absaudio/cover_cache.lua` | −20 net lines. Replaced 26-line inline mkdir-p with 6-line fs_helpers.mkdir_p call. Added `has_fs_helpers` require |
| `absaudio/book_detail.lua` | −8 net lines. Replaced 10-line inline mkdir in deps.fs with 4-line fs_helpers.mkdir_p delegation. Added `has_fs_helpers` require |

## Metrics

| Metric | Before | After | Delta |
|--------|--------|-------|-------|
| fs_helpers.lua lines | N/A | 93 | **+93** (new) |
| test_fs_helpers.lua tests | N/A | 12 | **+12** (new) |
| cover_cache.lua lines | 141 | 127 | **−14** |
| book_detail.lua lines | 1157 | 1149 | **−8** |
| Total inline mkdir code | ~36 lines (2 sites) | ~10 lines (2 one-liners) | **−26** |
| Total test suite | 329 pass | 341 pass | **+12** |

## Next Steps

- Incrementally replace remaining inline `get_file_size`, `delete_file`, `delete_dir` wrappers in `book_detail.lua` (lines 896–897, 926–929, 973–976, 1074–1075, 1108) with `fs_helpers.*` calls as those code paths are touched
