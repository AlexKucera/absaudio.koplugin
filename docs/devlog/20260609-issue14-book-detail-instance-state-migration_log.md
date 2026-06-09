# Issue #14: Book Detail Instance State Migration

**Date:** 2026-06-09
**Type:** issue (architecture deepening)
**Status:** Complete

## What was done

Migrated the book detail widget from module-level mutable state to instance-scoped state on `self`. Previously, `_on_back` and `_on_download` were module-level locals that got overwritten on each `detail.show()` call, meaning sequential calls would corrupt earlier widget instances.

## Changes

### `absaudio/book_detail.lua`
- **Removed** module-level locals `_on_back`, `_on_download` (lines 48-49)
- **Removed** module-level `_current_callbacks` (was temporary during implementation)
- `detail.show()` now passes `callbacks` as explicit parameter to `_fetchAndShow` and `_showFromManifestOrError`
- `_renderView(item, callbacks)` passes callbacks through `BookDetailView:new{}` constructor
- `BookDetailView` stores `self.on_back` and `self.on_download` from constructor opts
- `_addDownloadStatus` reads from `self.on_download` (captured into local for inner closure)
- `onClose` reads from `self.on_back`

### `spec/test_book_detail.lua`
- Added test: "callbacks are isolated between sequential show() calls" — creates two views with different callbacks, verifies each uses its own
- Added test: "on_download callback uses instance state" — verifies `self.on_download` is a function and works correctly

## Decisions & Rationale

- Callbacks threaded as explicit parameters through the call chain (`show` → `_fetchAndShow`/`_showFromManifestOrError` → `_renderView` → constructor) rather than stored on the module table. This avoids any shared mutable state.
- The `onTapDownload` closure captures `self.on_download` into a local variable before the closure, following the Lua closure best practice from AGENTS.md.
- Tests spy on `UIManager:show` (using `function(self, widget)` signature) to capture created widget instances and verify isolation directly.

## Gotchas & Fixes

- **UIManager:show spy signature**: First attempt used `function(widget)` but `UIManager:show(view)` passes `self` (UIManager table) as first arg. Fixed to `function(self, widget)`.
- **Missing closing brace**: When adding constructor fields for `on_back`/`on_download`, the `BookDetailView:new{}` call was missing its closing `}` before the `end`. Caught by Lua parse error.

## Acceptance Criteria

- [x] Module-level locals `_on_back`, `_on_download` are removed from book_detail.lua
- [x] BookDetailView stores callbacks on `self` (set via constructor opts → metatable lookup)
- [x] All widget methods that reference callbacks read from `self` instead of module-level locals
- [x] Tests verify callback isolation between sequential `show()` calls
- [x] All existing tests continue to pass (96 total: 11 book_detail + 85 others)

## Next Steps

- Issue #12 (Dashboard instance state migration) follows the same pattern
- Issue #11 parent epic continues with API seam, widget helpers, data/render split
