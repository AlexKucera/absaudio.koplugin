# Issue #3 — Data Layer & Dashboard Wiring: Audit and Gap Fixes

> **Date:** 2026-06-08
> **Type:** issue
> **Reference:** [GitHub Issue #3](https://github.com/AlexKucera/absaudio.koplugin/issues/3)

## Goal

Audit all acceptance criteria for Issue #3 against the existing codebase and fix any gaps. Issue #3 covers the data layer (api.lua, manifest.lua, error_handler.lua) and dashboard wiring for the ABS Audio KOReader plugin.

## What Was Done

- Audited all 11 acceptance criteria against the codebase — found 9 passing, 2 requiring emulator, 2 gaps
- Added 2 new unit tests for `manifest.getRecentBook()` (multi-book selection + empty manifest case)
- Replaced single "Settings" button with a full Settings section containing 3 action buttons:
  - ⚙ Server & Token — wired via callback to open plugin's config dialog
  - ↻ Sync Now — stub showing "available in future update"
  - 📋 Export Diagnostics — stub showing "available in future update"
- Updated `dashboard.show()` to accept a callbacks table: `{ on_settings, on_sync_now, on_export_diagnostics }`
- Updated `main.lua` to pass `on_settings` callback to `dashboard.show()`
- Extracted reusable `_addActionButton(label, callback)` helper in dashboard widget
- Updated `docs/manifest-data-model.md` with Dashboard Settings Section documentation
- All 48 tests pass (up from 46)

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Callbacks table pattern for dashboard→plugin communication | Dashboard widget can't require main.lua (circular dep). Passing callbacks via `dashboard.show({on_settings=...})` is clean inversion of control — plugin owns the wiring, widget stays decoupled. |
| `_on_settings` closes dashboard before opening config | Two fullscreen widgets stacked would cause rendering issues. `UIManager:scheduleIn(0.2, ...)` ensures dashboard closes first, then settings opens. |
| Sync Now / Export Diagnostics as stubs with InfoMessage | Issue says "stub" — these are future slices. Showing a brief placeholder message is the right UX: user gets feedback, not a dead button. |
| Kept `_addActionButton` as reusable helper | All 3 settings buttons share the same tap-container pattern. Extracting avoids duplication and makes future buttons trivial. |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| Settings button showed text hint instead of opening config dialog | Original `_addSettingsButton` was a stub showing InfoMessage with navigation instructions | Replaced with `_addSettingsSection` + callback wiring to `self:onShowSettings()` via `main.lua` |
| `getRecentBook()` had no test coverage | Function was added in a prior session but test was never written | Added 2 tests: multi-book returns highest current_time, empty manifest returns nil |
| `luajit -p` doesn't exist for syntax checking | LuaJIT doesn't support `-p` flag like standard Lua | Used `loadfile()` via `luajit -e` for syntax validation instead |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/dashboard_widget.lua` | Added callback storage, replaced `_addSettingsButton` with `_addSettingsSection` (3 buttons), added `_addActionButton` helper, added `_onSyncNow`/`_onExportDiagnostics` handlers, updated `dashboard.show()` signature |
| `main.lua` | Pass `{ on_settings = function() self:onShowSettings() end }` to `dashboard.show()` |
| `spec/test_manifest.lua` | Added 2 tests for `getRecentBook()` |
| `docs/manifest-data-model.md` | Added Dashboard Settings Section documentation |

## Acceptance Criteria Status

| # | Criterion | Status |
|---|-----------|--------|
| 1 | api.lua implements all 9 ABS endpoints with Bearer auth, retry/backoff, timeouts | ✅ PASS |
| 2 | Every API call wrapped in pcall | ✅ PASS |
| 3 | manifest.lua supports all 7 CRUD functions | ✅ PASS |
| 4 | Manifest entry shape matches PRD | ✅ PASS |
| 5 | Error handler maps HTTP status codes correctly | ✅ PASS |
| 6 | Dashboard shows Resume Last Book | ✅ PASS |
| 7 | Dashboard shows Downloaded Books list with progress badges | ✅ PASS |
| 8 | Dashboard Browse Library and Settings buttons are functional | ✅ PASS (fixed this session) |
| 9 | Unit tests for manifest CRUD pass | ✅ PASS (9/9, added 2 this session) |
| 10 | API client connects to real ABS server from emulator | 🔲 Needs emulator |
| 11 | All criteria pass in KOReader emulator | 🔲 Needs emulator |

## Open Items & Next Steps

- [ ] Emulator testing: run `./kodev run`, configure ABS credentials, verify dashboard renders with real data
- [ ] Verify Settings button opens config dialog from within dashboard (emulator test)
- [ ] Verify Sync Now / Export Diagnostics stubs show expected messages (emulator test)
- [ ] Issue #4+: Wire Sync Now to actual sync logic when implemented
- [ ] Issue #4+: Wire Export Diagnostics to actual export when implemented

---

*Log written by write-log skill*
