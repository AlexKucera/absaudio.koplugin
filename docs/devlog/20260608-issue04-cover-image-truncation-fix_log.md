# Issue #4 — Fix cover images displaying only half-loaded / top few lines

> **Date:** 2026-06-08
> **Type:** issue
> **Reference:** Issue #4 — Library browser + Book detail view (follow-up fix)

## Goal

Fix cover images in the library browser that displayed only the top few lines or appeared "half-loaded". Even leaving and re-entering the library didn't refresh the broken display.

## What Was Done

- **`absaudio/cover_cache.lua`** — Replaced the streaming `file_sink` approach (which wrote socket chunks directly to an open file handle) with `ltn12.sink.table()` pattern: collect the complete HTTP response body in a Lua table, then write the entire blob to disk in one `file:write()` call. Added `ltn12` module loading alongside `lfs` and `api`. Added byte count to the cover-cached log message for debugging (`"Cover cached: <id> (<N> bytes)"`).
- **`api.lua`** — Changed `getCover` endpoint's `Accept` header from `application/json` (inherited from `build_headers()`) to `image/*,*/*` to avoid confusing the server about what content type we expect.
- **`spec/test_cover_cache.lua`** — Added `ltn12` mock module (provides `sink.table` function). Updated mock `getCover` to properly simulate streaming data chunks to the ltn12 sink, matching the real LuaSocket flow.
- Cleared truncated cache files from `/tmp/abs_covers/` so fresh covers will be fetched.

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Use `ltn12.sink.table()` + bulk write instead of streaming `file_sink` | This is the same proven pattern used by all other API endpoints in the plugin (getLibraries, getLibraryItems, etc.). The streaming approach produced truncated files — every cached file was an exact multiple of 1300 bytes (the TLS chunk size), indicating the socket connection closed before all data was received but the partial file was already flushed to disk. |
| Changed Accept header to `image/*,*/*` | The cover endpoint was using `build_headers()` which sets `Accept: application/json`. For a binary image endpoint, `image/*,*/*` is more appropriate and avoids server-side content negotiation surprises. |
| Single `file:write(cover_data)` after full collection | Eliminates the window where a partial file exists on disk. If the HTTP request fails or times out, no file is created at all — the next attempt starts clean. |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| Covers displayed only top few lines visible, rest blank | Cover files on disk were truncated. Every cached file was an exact multiple of 1300 bytes (the TLS record/chunk size): 1300, 2600, 3900, 5200, 6500, 7800, 10400. A real cover via curl was 8716 bytes, but the cached version was only 3900. | Replaced streaming `file_sink` with `ltn12.sink.table()` — collect full response, then write in one shot. |
| Leaving and re-entering library didn't fix display | KOReader's `ImageWidget` caches rendered images. The partial JPEG was decoded once (with MuPDF fallback after TurboJPEG failed), and the cached render was reused on every subsequent paint. | Fix is at the source — ensure files are complete. The display issue was a symptom, not the cause. |
| TurboJPEG failed on every cover image (`"decoding JPEG file"` error) | MuPDF logged `"premature end of file in jpeg"` — confirming the files were truncated. TurboJPEG couldn't decode them at all. | Fixed by ensuring complete file writes. TurboJPEG should work correctly with full JPEGs. |
| Initial misdiagnosis: thought server was returning WebP | An unauthenticated `curl` test (no bearer token) returned a WebP response. The actual authenticated endpoint returns JPEG. User confirmed files on disk in the ABS media directory are JPEGs. | Corrected understanding — the format is JPEG, `.jpg` extension is correct. The WebP finding was an artifact of testing without auth. |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/cover_cache.lua` | Replaced streaming file_sink with `ltn12.sink.table()` + bulk write; added ltn12 loading; added byte count to log |
| `api.lua` | Changed `getCover` Accept header from `application/json` to `image/*,*/*` |
| `spec/test_cover_cache.lua` | Added `ltn12` mock; updated mock `getCover` to simulate streaming to sink |

## Test Results

75 tests, 0 failures (unchanged — all existing tests pass with updated mocks).

## Open Items & Next Steps

- [ ] **Emulator re-test** — Verify covers now display fully (no truncation, no TurboJPEG fallback)
- [ ] **Performance check** — `ltn12.sink.table()` collects full response in memory before writing. For very large covers this is fine (typical ABS covers are 5-50KB), but worth noting if covers ever become huge.
- [ ] **Cover display after fetch** — Verify that `_scheduleCoverFetch()` → `_view:_refresh()` correctly updates the display with complete covers (no flicker, correct scroll position)
- [ ] **Device test** — Test on real KOReader hardware to confirm end-to-end cover flow

---

*Log written by write-log skill*
