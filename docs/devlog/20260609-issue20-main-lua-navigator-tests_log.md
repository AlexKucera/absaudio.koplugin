# Issue #20: main.lua Navigator Registration Tests

> **Date:** 2026-06-09
> **Type:** issue
> **Reference:** Issue #20 — Navigator module refactor (acceptance criterion #8)

## Goal

Create `spec/test_main.lua` with test coverage for main.lua's navigator integration — specifically verifying that `_registerScreens()` registers all 3 screens, `onOpenDashboard()` wires callbacks correctly, and dispatcher events route to the right handlers. This was the last incomplete acceptance criterion from the Issue #20 navigator refactor.

## What Was Done

- Created `spec/test_main.lua` with 10 tests covering:
  1. ABSAudio module loads as WidgetContainer with correct name
  2. `_registerScreens()` registers dashboard, browser, detail with navigator
  3. `_registerScreens()` registers callable `show` functions (not bare data)
  4. `onOpenDashboard()` calls `_registerScreens()` when configured
  5. `onOpenDashboard()` schedules `nav.reset("dashboard", data)` via `UIManager:scheduleIn`
  6. `onOpenDashboard()` passes `on_settings`, `on_sync_now`, `on_export_diagnostics` callbacks
  7. `onOpenDashboard()` shows settings dialog on first run (when not configured)
  8. `addToMainMenu()` creates correct menu structure with Open dashboard and Settings
  9. `ABSAudioOpen` dispatcher event routes to `onOpenDashboard()`
  10. `ABSAudioSettings` dispatcher event routes to `onShowSettings()`
- Built comprehensive KOReader dependency stub infrastructure to allow main.lua to load outside KOReader
- All 196 tests pass across 14 test files (10 new)

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Capture `scheduleIn` callbacks rather than executing inline | `onOpenDashboard()` defers dashboard show via `UIManager:scheduleIn(0.1, fn)` — tests capture the scheduled fn and execute it explicitly to verify `nav.reset` is called with correct args |
| Reload main.lua in first-run test | `config.is_configured()` is read at module load time via `require("config")` stub — to test the "not configured" branch, the test overrides `package.loaded["config"].is_configured`, then reloads main.lua to pick up the new mock |
| Custom MultiInputDialog stub instead of `make_widget_stub()` | `onShowSettings()` calls `settings_dialog:onShowKeyboard()` on the instance returned by `MultiInputDialog:new{...}` — generic widget stub's `new()` doesn't propagate methods to instances, so a custom stub with explicit `onShowKeyboard` and `getFields` on each instance was needed |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| `library_browser` failed to load — only 2 of 3 screens registered | `ui/widget/container/leftcontainer` stub was registered under wrong path `ui/widget/leftcontainer` | Corrected stub path to `ui/widget/container/leftcontainer` matching `library_browser.lua:26` |
| `WidgetContainer:new{...}` error — `attempt to call a nil value (method 'new')` | KOReader's WidgetContainer has `:new()` at base class level; stub only defined `:extend()` | Added `WC_mt:new(opts)` method to base metatable alongside `:extend()` |
| `onShowKeyboard` nil on settings dialog test | `make_widget_stub().new()` creates bare tables without inheriting stub methods; `main.lua:237` calls `settings_dialog:onShowKeyboard()` | Replaced generic `make_widget_stub()` for MultiInputDialog with custom stub whose `new()` explicitly sets `onShowKeyboard`, `getFields`, and `getSize` on each instance |
| Stubs loaded after widget modules that need them | Lua executes `package.loaded` assignments top-to-bottom; leftcontainer stub was placed after the widget stubs that trigger its loading | Moved `ui/widget/container/leftcontainer` stub into the same block as other container stubs, before any widget module stubs |

## Files Changed

| File | Change Summary |
|------|---------------|
| `spec/test_main.lua` | Created — 10 tests for main.lua navigator integration, menu structure, dispatcher routing, and first-run behavior |

## Test Results

```
spec/test_main.lua — 10 passed, 0 failed
Full suite — 196 passed, 0 failed (14 test files)
```

## Open Items & Next Steps

- [x] Acceptance criterion #8 (main.lua tests for navigator registration) — **Complete**
- [ ] All 9 acceptance criteria for Issue #20 now verified — ready to close

---

*Log written by write-log skill*
