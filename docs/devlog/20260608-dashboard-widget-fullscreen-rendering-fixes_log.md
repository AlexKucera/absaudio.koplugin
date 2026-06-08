# Dashboard Widget Fullscreen Rendering & Event Handling Fixes

> **Date:** 2026-06-08
> **Type:** slice
> **Reference:** Slice 2 — Data layer & dashboard integration

## Goal

Get the dashboard widget rendering as a proper fullscreen overlay in the KOReader emulator, fix all crash-on-tap bugs, and add back/swipe-to-close navigation so users can exit the dashboard.

## What Was Done

- Changed `keep_menu_open = false` on "Open dashboard" menu item so the TouchMenu closes before dashboard renders
- Wrapped `dashboard.show()` in `UIManager:scheduleIn(0.1, ...)` to defer rendering until after menu teardown completes
- Added `covers_fullscreen = true` to DashboardView class for UIManager repaint hint
- Set FrameContainer to exact screen dimensions (`width = screen_size.w, height = screen_size.h`) with `padding = 0, bordersize = 0, margin = 0`
- Fixed font crash: replaced non-existent `Font:getFace("x_large_tfont")` with `Font:getFace("tfont", 26)`
- Fixed tap callback crash: replaced `dashboard_view` local capture (out-of-scope in callback closures) with `self.dashboard_ref` stored on DashboardView, propagated to each tap_container via `tap_container.dashboard_ref = self.dashboard_ref`
- Added Back key handler: `self.key_events.Close = { { Device.input.group.Back } }` → calls `onClose()` → `UIManager:close(self)`
- Added swipe-down handler: `ges_events.Swipe` → `onSwipe` checks `ges_ev.direction == "south"` → calls `onClose()`
- Added top padding (`VerticalSpan`) to content group so title isn't flush against screen edge
- Fixed syntax error: missing `end` for `onOpenDashboard` function after adding `scheduleIn` wrapper

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| `UIManager:scheduleIn(0.1, ...)` to defer dashboard show | TouchMenu calls item callback synchronously *before* `closeMenu()`, so the dashboard would render while the menu is still in the widget stack. Scheduling defers the show to the next event loop tick after the menu is torn down. |
| `self.dashboard_ref` pattern instead of local capture | Tap callbacks defined via `function tap_container:onTapBrowse()` have `self` = tap_container, not the DashboardView. Storing `dashboard_ref` on both DashboardView and each tap_container ensures callbacks can reach dashboard methods regardless of `self` binding. |
| `covers_fullscreen = true` class property | Required by UIManager's `_repaint()` to know this widget covers the entire screen — without it, the underlying view isn't properly masked and the widget may be sized incorrectly. |
| Swipe-down to close (not tap-outside) | ScrollableContainer already handles taps for scrolling. Swipe-down is the standard KOReader "dismiss fullscreen" gesture (used by BookStatusWidget, ImageViewer, etc.). |
| `Font:getFace("tfont", 26)` for title | KOReader's valid font names are: `cfont`, `tfont`, `smalltfont`, `x_smalltfont`, `largeffont`, `scfont`. Using the name + explicit size pattern is the idiomatic way to get a specific size. |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| Dashboard renders crammed inside menu popup at top of screen | `keep_menu_open = true` on the menu item + TouchMenu calls callback before `closeMenu()` | Changed to `keep_menu_open = false` and wrapped `dashboard.show()` in `UIManager:scheduleIn(0.1, ...)` |
| Crash: `attempt to perform arithmetic on local 'px' (a nil value)` in `Font:getFace` | Font name `"x_large_tfont"` doesn't exist in KOReader's font map — `Font:getFace` returns nil, then `scaleBySize` fails | Changed to `Font:getFace("tfont", 26)` — a valid font name with explicit size |
| Crash: `attempt to index global 'dashboard_view' (a nil value)` on library/settings tap | `dashboard_view` was a local in `init()`, out of scope when tap callbacks fire in separate methods | Stored as `self.dashboard_ref` on DashboardView, then propagated to each `tap_container.dashboard_ref` before defining callbacks |
| No way to exit dashboard — stuck fullscreen | No key/gesture handlers registered to close the widget | Added `key_events.Close` (Back key) and `ges_events.Swipe` (swipe down) both calling `onClose()` → `UIManager:close(self)` |
| Syntax error: `'end' expected near '<eof>'` on line 293 | Missing `end` to close `onOpenDashboard` function after the `scheduleIn` edit added a new `if/else/end` block | Added missing `end` statement |

## Files Changed

| File | Change Summary |
|------|---------------|
| `main.lua` | Changed `keep_menu_open` to `false`; wrapped `dashboard.show()` in `UIManager:scheduleIn(0.1, ...)` |
| `absaudio/dashboard_widget.lua` | Full rewrite from placeholder to working fullscreen widget: added all KOReader UI imports, `covers_fullscreen`, proper FrameContainer sizing, `dashboard_ref` pattern for callbacks, Back key + swipe-down close handlers, top padding |

## Open Items & Next Steps

- [ ] Pre-existing bug: `main.lua:181` (`onSaveSettings`) crashes with "attempt to index local 'fields' (a nil value)" — needs fix
- [ ] `_onBrowseLibrary` and `_onOpenSettings` currently show placeholder InfoMessage dialogs — need real implementations
- [ ] `_onResumeBook` needs playback integration (future slice)
- [ ] Test on PocketBook Era Color hardware (touch gestures may differ from desktop emulator)
- [ ] Consider adding a visible close/dismiss button for non-gesture users

---

*Log written by write-log skill*
