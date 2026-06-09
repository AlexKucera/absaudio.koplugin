# Progress

## Status
Issue #12 Complete — Dashboard instance state migration

## Tasks
- [x] Write failing tests for callback isolation (RED)
- [x] Remove module-level locals `_on_settings`, `_on_sync_now`, `_on_export_diagnostics`
- [x] Pass callbacks through DashboardView constructor
- [x] Update `_onOpenSettings`, `_onSyncNow`, `_onExportDiagnostics` to read from `self`
- [x] Update `_onBrowseLibrary` closures to capture all 3 callbacks
- [x] All 103 tests pass

## Files Changed
- `absaudio/dashboard_widget.lua` — Removed module-level locals, constructor passes callbacks, methods read from self
- `spec/test_dashboard_widget.lua` — NEW: 7 tests covering widget creation, instance state, callback isolation, method dispatch

## Notes
- Restored `absaudio/library_browser.lua` and `spec/test_library_browser.lua` to committed state (had unrelated uncommitted changes from a prior session)
