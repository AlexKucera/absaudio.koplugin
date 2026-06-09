# Dashboard data/render split

> **Date:** 2026-06-09
> **Type:** issue
> **Reference:** [Issue #17](https://github.com/AlexKucera/absaudio.koplugin/issues/17)

## Goal

Split the dashboard widget's data preparation from its rendering by extracting a `dashboard.prepare()` function. This separates data fetching (manifest.init, getRecentBook, getAllBooks) from widget creation, enabling pure-data testing without KOReader widget imports.

## What Was Done

- Extracted `dashboard.prepare()` function that returns `(data, nil)` on success or `(nil, error_info)` on failure
- Data table contains `recent_book` (single book or nil) and `all_books` (array)
- Refactored `dashboard.show()` to call `prepare()` then pass `dashboard_data` to DashboardView via constructor
- Updated `_addResumeSection()` to read `self.dashboard_data.recent_book` instead of calling manifest directly
- Updated `_addDownloadedBooksSection()` to read `self.dashboard_data.all_books` instead of calling manifest directly
- Added 4 new tests: 3 pure-data tests for `prepare()` + 1 integration test verifying show() passes prepared data
- All 166 tests pass across all test files (up from 162)

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| `prepare()` returns `(data, nil)` or `(nil, error_info)` | Follows Lua idiomatic multi-return pattern; error_info is a structured table `{ type, message }` for future error handling |
| `dashboard_data` passed via DashboardView constructor | Keeps data flow explicit — view receives everything it needs at construction time, no hidden manifest dependency |
| Empty manifest returns valid empty data, not error | An empty manifest is a valid state (no books downloaded yet), not an error condition |
| Manifest unavailability returns error | Only truly broken states (missing module) return errors |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| None — straightforward extraction | N/A | N/A |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/dashboard_widget.lua` | Extracted `prepare()`, refactored `show()` to call it, updated `_addResumeSection` and `_addDownloadedBooksSection` to use `self.dashboard_data` |
| `spec/test_dashboard_widget.lua` | Added 4 tests: prepare-with-books, prepare-empty, prepare-manifest-unavailable, show-passes-prepared-data |

## Open Items & Next Steps

- None — all acceptance criteria met

---

*Log written by write-log skill*
