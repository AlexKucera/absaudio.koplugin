# Dashboard Cover Images

> **Date:** 2026-06-10
> **Type:** generic
> **Reference:** User request — add cover images to dashboard book entries matching library browser layout

## Goal

Add cover thumbnail images (80×100 DPI-scaled) to both the "Resume Last Book" and "Downloaded Books" sections on the ABS Audio dashboard. Layout should match the library browser's horizontal row: `[cover] [padding] [title + author + progress text]`. Books without cached covers should show a gray placeholder with 🎵 icon (same as library browser fallback).

## What Was Done

- **Added `_buildBookRow(book, title_text)` shared helper** to `absaudio/dashboard_widget.lua` (lines 280–335) — builds a HorizontalGroup with cover ImageWidget or gray FrameContainer placeholder on the left, TextBoxWidget text on the right. Matches library browser's `_addBookRow()` exactly.
- **Refactored `_addResumeSection()`** (line ~252) — replaced raw TextBoxWidget with `_buildBookRow()` call, fixed dimen to use `Screen:scaleBySize(100)` instead of `info_widget:getSize().h`
- **Refactored `_addDownloadedBooksSection()`** (line ~337) — same pattern: replaced raw TextBoxWidget with `_buildBookRow()`, fixed dimen references
- **Added `cover_cache.init()` to `DashboardView:init()`** (line ~130) — idempotent initialization of cover cache using `{settings}/absaudio_covers` directory, same as library_browser and book_detail
- **Added widget imports**: `HorizontalGroup`, `HorizontalSpan`, `ImageWidget`, `LeftContainer`, plus optional `cover_cache` via pcall
- **Added 4 new tests** to `spec/test_dashboard_widget.lua`:
  1. Downloaded book entry includes HorizontalGroup when cover is cached
  2. Downloaded book entry shows placeholder when no cover is cached
  3. Resume section uses HorizontalGroup layout when book has cover
  4. Book without `abs_item_id` renders placeholder without crash (legacy data edge case)
- **Added test infrastructure mocks**: `datastorage`, `ImageWidget`, `HorizontalGroup`, `HorizontalSpan`, `LeftContainer`, `cover_cache`, global `_G.Device` and `_G.Screen`
- **Fixed `scaleBySize` mock** — colon syntax passes `self` as first arg; changed from `function(n) return n end` to `function(_, n) return n end`

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Shared `_buildBookRow()` helper for both resume + downloaded sections | DRY — both sections need identical cover+text layout; avoids duplicating ~50 lines of cover resolution code |
| Same 80×100 size as library browser | User explicitly requested "same size as the covers in the library list"; visual consistency across screens |
| Gray 🎵 placeholder for missing covers | User chose this option over text-only or auto-fetch; matches existing library browser fallback pattern |
| No auto-fetch of covers on dashboard | Library browser does lazy fetch+refresh, but dashboard is a quick-glance screen; covers appear if already cached from library browsing or downloads |
| `hasCachedCover` check only (no fetch trigger) | Dashboard loads fast; fetching covers would add latency. Covers get cached when user visits library browser. |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| `module 'datastorage' not found` in tests | New `cover_cache.init()` call requires KOReader's `datastorage` module which doesn't exist in test env | Added `package.loaded["datastorage"] = { getSettingsDir = function() ... }` mock to test file |
| `attempt to perform arithmetic on a table value (thumb_width)` | Mock `scaleBySize = function(n) return n end` — Lua colon syntax (`Screen:scaleBySize(80)`) passes `Screen` table as implicit first arg, so function returned `self` not `80` | Changed mock to `function(_, n) return n end` to accept and discard the implicit `self` arg |
| `Device.screen` vs `_G.Screen` | Dashboard uses `local Screen = Device.screen` (capital D), but test mocks only set `package.loaded["device"]` (lowercase) | Added `_G.Device = mock_device` so the capital-D global that KOReader sets up at runtime is available |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/dashboard_widget.lua` | Added `_buildBookRow()` helper; refactored resume + downloaded sections to use it; added cover_cache init; added 4 widget imports + cover_cache import |
| `spec/test_dashboard_widget.lua` | Added 4 new tests (cover layout, placeholder, resume section, nil abs_item_id edge case); added datastorage/ImageWidget/HG/HS/LC/cover_cache/Device/Screen mocks; fixed scaleBySize mock signature |

## Test Results

```
20 passed, 0 failed (dashboard_widget)
326 passed, 0 failed (full suite — no regressions)
```

## Open Items & Next Steps

- None — feature is complete and fully tested
- Future enhancement: could add lazy cover fetch to dashboard (like library browser's `_scheduleCoverFetch`) if users want covers to appear without visiting library browser first

---

*Log written by write-log skill*
