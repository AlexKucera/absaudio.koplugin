# Dashboard Downloaded Books → Detail View Navigation

> **Date:** 2026-06-10
> **Type:** generic
> **Reference:** N/A

## Goal

Tapping a downloaded book in the dashboard's "Downloaded Books" section did nothing. The book entries were rendered as plain `TextBoxWidget`s with no tap handler. The goal was to make them tappable so they navigate to the book detail view, matching the behavior of the library browser.

## What Was Done

- Added `DashboardView:_onBookTap(book)` method to `dashboard_widget.lua` — maps `book.abs_item_id` → `item.id` and pushes `"detail"` screen via navigator
- Changed `_addDownloadedBooksSection()` to wrap each book `TextBoxWidget` in an `InputContainer` with a `TapBook` gesture event, following the same pattern as the Resume and Browse Library buttons
- Added 2 TDD tests in `test_dashboard_widget.lua`: one for the `_onBookTap` method, one for the tappable container wiring

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Map `book.abs_item_id` → `item.id` in `_onBookTap` | Manifest stores book IDs as `abs_item_id`, but `detail.show()` expects `item.id`. Mapping at the tap boundary keeps the detail view's interface unchanged. |
| Construct minimal `{id, title, author}` item instead of passing raw manifest book | Manifest book shape differs from the ABS API item shape that `detail.prepare()` expects. Passing only the fields `detail.show` needs avoids leaking manifest internals. |
| Follow existing `dashboard_ref` / `onTapX` pattern | Consistency with Resume (`onTapResume` → `_onResumeBook`), Browse (`onTapBrowse` → `_onBrowseLibrary`), and library browser (`onTapBook` → `onBookTap`). |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| First test attempt got `#tap_containers == 0` | Test overwrote `package.loaded["manifest"]` after `dashboard_widget` was already loaded and holding a reference to the old manifest mock. | Used `setup_manifest_mock()` helper + `package.loaded["absaudio/dashboard_widget"] = nil` + fresh `require()` to reload module against new manifest, matching the pattern used by other tests in the file. |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/dashboard_widget.lua` | Added `_onBookTap(book)` method; wrapped downloaded book entries in tappable `InputContainer` with `TapBook` gesture |
| `spec/test_dashboard_widget.lua` | Added 2 tests: `_onBookTap` pushes detail via navigator; tappable containers wired to `_onBookTap` |

## Open Items & Next Steps

- [ ] Test on device: tap a downloaded book on the dashboard, verify it opens detail view
- [ ] Consider whether the dashboard detail view should support `on_download` / `on_delete` / `on_open_ebook` callbacks (currently navigates with item-only data — download/delete buttons won't appear since no callbacks are passed)
- [ ] The "Resume" section book tap (`_onResumeBook`) could also navigate to detail instead of just resuming playback — future UX decision

---

*Log written by write-log skill*
