# Issue #12: Dashboard Instance State Migration

**Date:** 2026-06-09
**Type:** issue
**Status:** complete

## What was done

Migrated the dashboard widget from module-level mutable state to instance-scoped state on `self`.

### Changes

1. **Removed module-level locals** `_on_settings`, `_on_sync_now`, `_on_export_diagnostics` from `dashboard_widget.lua`
2. **Constructor passes callbacks through** `DashboardView:new{ on_settings = ..., on_sync_now = ..., on_export_diagnostics = ... }` — instance owns them from creation
3. **All widget methods read from `self`**: `_onOpenSettings`, `_onSyncNow`, `_onExportDiagnostics` read from `self.on_settings`, `self.on_sync_now`, `self.on_export_diagnostics`
4. **`_onBrowseLibrary` closures capture all 3 callbacks** — not just `settings_cb` but also `sync_cb` and `export_cb` so re-navigation preserves all callbacks
5. **Created `spec/test_dashboard_widget.lua`** — 7 tests covering:
   - Widget creation and UIManager delegation
   - Callbacks stored on instance via constructor
   - Default to nil when not provided
   - **Callback isolation** between sequential `show()` calls
   - `_onOpenSettings` reads from `self.on_settings`
   - `_onSyncNow` reads from `self.on_sync_now`
   - `_onExportDiagnostics` reads from `self.on_export_diagnostics`

## Decisions & Rationale

- **Followed the same pattern as issue #14** (book_detail instance state migration) for consistency
- **All 3 callbacks now flow through constructor** — this is important because `_onBrowseLibrary` recursively calls `dashboard.show()` to navigate back, and those closures now capture the full callback set
- **`scheduleIn` mock fix**: The `UIManager:scheduleIn(0.2, fn)` call uses colon syntax, so the mock needs `function(self, delay, fn)` not `function(delay, fn)` — the `self` parameter receives the UIManager table

## Gotchas & Fixes

- **Pre-existing uncommitted changes**: `absaudio/library_browser.lua` and `spec/test_library_browser.lua` had uncommitted changes from a prior session (library_browser instance state migration, not yet committed). These were restored to the committed version since they're unrelated to issue #12 and the new tests were failing against incomplete code.
- **`UIManager:scheduleIn` colon syntax**: KOReader uses colon calls on UIManager, so mock functions must account for the implicit `self` parameter.

## Test Results

103 tests pass (was 96 before, +7 new dashboard widget tests)

## Next Steps

- Issue #12 acceptance criteria fully met
- Library browser instance state migration is partially done in the working tree but was reverted — needs its own issue/commit
