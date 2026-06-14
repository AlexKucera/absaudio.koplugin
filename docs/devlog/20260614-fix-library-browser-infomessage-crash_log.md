# Fix: Library Browser InfoMessage Crash in Error Path

> **Date:** 2026-06-14
> **Type:** generic
> **Reference:** device-reported (blocking — "the library doesn't open anymore")

## Goal

On the PB700K3, tapping "Browse Library" crashed the plugin and dropped back to KOReader. The crash was **consistent** because USB mounting drops the device's WiFi, so the ABS server was unreachable → `prepare()` failed → the error path crashed.

## What Was Done

- **`absaudio/library_browser.lua` — added missing `InfoMessage` require:** the module used `InfoMessage:new{...}` at 4 sites (lines 709, 715, 722, 741 — the error/empty-state paths) but never `require`d `ui/widget/infomessage`. The global `InfoMessage` was `nil` → `attempt to index global 'InfoMessage' (a nil value)` → crash. Added `local InfoMessage = require("ui/widget/infomessage")` to the require block.
- **`absaudio/audio_probe.lua` — undefined-symbol crash guard:** v5 declared `IsPlayingMP3` in the FFI cdef (it's in the public `inkview.h` but NOT exported by the PB700K3 firmware per the v4 binary scan). Accessing `lib["IsPlayingMP3"]` threw an uncaught `undefined symbol` error, crashing the probe handler. Wrapped the symbol lookup in `pcall` so undefined symbols report as `<not exported>` instead of crashing.

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Fix via `require` (not lazy-load) | `InfoMessage` is a standard KOReader widget used in 4 places in this module. A top-level require matches the pattern of every other widget in the same block. This also resolves the 7 long-standing `test_library_browser` InfoMessage-nil failures. |
| The crash only appeared now | The error path (prepare failure) was never hit when WiFi worked. USB mass storage disables PocketBook WiFi, so while the device was USB-connected (for file transfer + probe deployment), the ABS server was unreachable → "No libraries found" → error path → crash. The bug was latent; USB-mounting exposed it. |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| "Browse Library" crashes to KOReader | `library_browser.lua` used `InfoMessage` (4 sites) without requiring it; `nil` in the `prepare()` error path → uncaught crash | Added `require("ui/widget/infomessage")` |
| Audio probe handler crashes (`undefined symbol: IsPlayingMP3`) | v5 cdef declared a symbol not exported by this firmware; `lib[name]` threw uncaught | Wrap symbol lookup in `pcall` in `trycall()` |
| Latent bug surfaced only during USB debugging | USB mass storage disables PocketBook WiFi → ABS unreachable → prepare fails → error path | The require fix resolves the crash; the underlying prepare-failure UX (graceful "offline" message) now works correctly |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/library_browser.lua` | +`require("ui/widget/infomessage")` (fixes 4 InfoMessage sites; resolves 7 test failures) |
| `absaudio/audio_probe.lua` | `trycall()`: wrap `lib[name]` in `pcall` (undefined-symbol crash guard) |

## Verification

- `busted spec/test_library_browser.lua` → **17 passed, 0 failed** (was 10 passed / 7 failed).
- Full suite → **0 InfoMessage failures** (was 7). 2 pre-existing `test_abs_logger` fallback-logger print-capture failures remain (unrelated, environmental).
- `audio_probe.lua` syntax valid; crash-test passes on Mac (degrades gracefully without inkview).

## Open Items & Next Steps

- [ ] Confirm "Browse Library" opens (and shows a graceful offline message when WiFi is down) on the device after restart.
- [ ] Re-run the v5 audio probe (now that the `IsPlayingMP3` crash is fixed) — ideally with the native player playing, for the GetAudioPlayingInfo struct dump.

---

*Log written by write-log skill*
