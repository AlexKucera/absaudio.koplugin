# Issue #4 Acceptance Criteria Audit & Gap Closure

> **Date:** 2026-06-09
> **Type:** issue
> **Reference:** [GitHub Issue #4](https://github.com/AlexKucera/absaudio.koplugin/issues/4)

## Goal

Audit all 12 acceptance criteria for Issue #4 (Library Browser & Book Detail View), identify gaps, and close them with TDD. Ensure every criterion has automated test coverage.

## What Was Done

- Audited all 12 acceptance criteria against the codebase (library_browser.lua, book_detail.lua, cover_cache.lua, library_store.lua, dashboard_widget.lua, api.lua, main.lua)
- Identified two gaps:
  1. **Criterion 10 (offline behaviour)**: Browse Library button was not visually greyed out when offline — no way to detect failed fetch state
  2. **Test coverage gap**: No `spec/test_book_detail.lua` existed — offline fallback behaviour was untested
- Added `wasLastFetchSuccessful()` public API to `library_store` — returns `nil` (never tried), `true` (success), or `false` (failure)
- Updated `dashboard_widget._addBrowseLibraryButton()` to grey out and disable tap when `wasLastFetchSuccessful() == false` or API not configured
- Created `spec/test_book_detail.lua` with 9 tests covering `_mergeItemData`, `_itemFromManifest`, and offline fallback paths in `show()`
- Added 5 tests for `wasLastFetchSuccessful` to `spec/test_library_store.lua`
- Final test count: **94 tests, 0 failures** across 8 test files

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| `wasLastFetchSuccessful()` returns tri-state (nil/true/false) | Distinguishes "never tried to fetch" from "tried and succeeded" from "tried and failed". The nil state avoids greying out the button before any fetch attempt. |
| Grey-out logic checks `== false` (not falsy) | `nil` means "first time, haven't tried yet" — should show button normally. Only `false` means "tried and failed" → grey out. |
| Book detail tests mock at the `show()` public API level | Tests exercise the full decision tree (API available → manifest fallback → error handler) without requiring KOReader widget runtime. |
| Added `library_store` import via `pcall` in dashboard_widget | Graceful degradation: if library_store isn't available, button just isn't greyed out (same as before). |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| `library_store.lua` had duplicate `current_sort` declaration and duplicate `init` function body | Prior edit session left a stale copy from an older file version | Removed duplicate during edit; the file now has a single clean declaration |
| GitNexus `npx gitnexus analyze` fails with `ERR_MODULE_NOT_FOUND` | The global `gitnexus` binary works but `npx gitnexus` pulls a wrong/incompatible package | Used `gitnexus` directly from `$PATH` (`/opt/homebrew/bin/gitnexus`) |

## Acceptance Criteria — Final Status

| # | Criterion | Status |
|---|-----------|--------|
| 1 | Fetch all items in one API call | ✅ PASS |
| 2 | Paginated list (~25/page) with nav | ✅ PASS |
| 3 | Cover thumbnail, title, author, duration | ✅ PASS |
| 4 | Search filters by title/author | ✅ PASS |
| 5 | Sort button cycles 6 modes | ✅ PASS |
| 6 | Client-side sort/pagination | ✅ PASS |
| 7 | Tapping book opens detail view | ✅ PASS |
| 8 | Detail view: all sections | ✅ PASS |
| 9 | Cover art cached + placeholder | ✅ PASS |
| 10 | Offline: Browse Library greyed out + WiFi message | ✅ PASS (fixed this session) |
| 11 | Downloaded books: cover from local disk | ✅ PASS |
| 12 | All pass in emulator | ❓ Needs manual verification |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/library_store.lua` | Added `last_fetch_ok` state tracking and `wasLastFetchSuccessful()` public API |
| `absaudio/dashboard_widget.lua` | Added `library_store` import; grey out Browse Library button when offline (disabled tap, grey text, reason message) |
| `spec/test_library_store.lua` | Added 5 tests for `wasLastFetchSuccessful` (nil/true/false/reset/multi-fetch tracking) |
| `spec/test_book_detail.lua` | New file — 9 tests: `_mergeItemData` (2), `_itemFromManifest` (2), `show` offline paths (5) |

## Open Items & Next Steps

- [ ] Manual emulator testing: `./kodev run` → verify all 12 criteria visually
- [ ] Test offline flow: disconnect emulator from network → verify greyed-out button + WiFi message in detail view
- [ ] Consider `./kodev wbuilder` for isolated widget iteration on the grey-out behaviour
- [ ] Issue #4 can be closed once emulator testing confirms all criteria

---

*Log written by write-log skill*
