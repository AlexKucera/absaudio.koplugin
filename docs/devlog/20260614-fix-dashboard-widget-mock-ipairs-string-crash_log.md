# Fix: test_dashboard_widget ipairs-on-string crash (Device.input.group mock shape)

> **Date:** 2026-06-14
> **Type:** generic
> **Reference:** resolves the pre-existing test debt noted in the
> [issue #32 log](20260614-issue32-audio-slice-a-pure-audio-math-library_log.md)
> ("test_dashboard_widget.lua (19 failing) … should be addressed in a separate
> housekeeping pass")

## Goal

Fix the long-standing crash in `spec/test_dashboard_widget.lua` — every dashboard
test failed with `./absaudio/dashboard_widget.lua:114: bad argument #1 to 'ipairs'
(table expected, got string)` (19 errors). Surfaced during issue #33's full-suite
verification; the user asked to fix it in the same session.

## What Was Done

- Corrected the `Device.input.group.Back` mock shape in **9 occurrences across 8
  spec files** from the bare-string `{ Back = "Back" }` to KOReader's real table
  shape `{ Back = { "Back" } }`:
  `test_dashboard_widget.lua`, `test_player.lua`, `test_ffmpeg_backend.lua`,
  `test_widget_helpers.lua`, `test_book_detail.lua`, `test_library_browser.lua`,
  `test_main.lua`, `test_downloader.lua` (×2).
- Recorded a concise mock-gotcha learning in `AGENTS.md` (KOReader UI section) so
  future test authors mock the `Device.input.group` interface correctly.

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| **Test-only fix; production code at `dashboard_widget.lua:114` left unchanged** | Verified against KOReader's real source (`frontend/device/input.lua`): every `group.<Name>` is a TABLE of key-name strings (`Back = { "Back" }`, `Cursor = { "Up", "Down", … }`). KOReader itself does `table.insert(self.group.Back, "Backspace")` (for the `backspace_as_back` setting) and `InputDialog` wraps it `{ { Device.input.group.Back } }`. The production `ipairs(Device.input.group.Back)` is therefore correct; it only crashed because the mock fed it a string. Adding defensive `type()` checks would be cargo-culting a risk that doesn't exist in production. |
| **Fixed all 9 occurrences, not just the crashing one** | Only `test_dashboard_widget` actively crashed (it builds a `DashboardView` with `hasKeys()=true` → reaches line 114). The other 7 files were latent — gated by `hasKeys()=false` so the bad mock was never read — but still misrepresented the KOReader interface. Fixing all prevents a future `hasKeys()=true` test from rediscovering the crash. |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| **`ipairs(Device.input.group.Back)` → "table expected, got string"** | The spec mocks set `input = { group = { Back = "Back" } }` (a bare string). KOReader defines `group.Back` as a **table** of key names; production code correctly calls `ipairs` on it. The mock misrepresented the interface. | Changed the mock to `{ Back = { "Back" } }` to match KOReader's real shape. |

## Files Changed

| File | Change Summary |
|------|---------------|
| `spec/test_dashboard_widget.lua` | `{ Back = "Back" }` → `{ Back = { "Back" } }` (1 occurrence; the crashing file) |
| `spec/test_player.lua` | same mock-shape fix (1 occurrence) |
| `spec/test_ffmpeg_backend.lua` | same mock-shape fix (1 occurrence) |
| `spec/test_widget_helpers.lua` | same mock-shape fix (1 occurrence) |
| `spec/test_book_detail.lua` | same mock-shape fix (1 occurrence) |
| `spec/test_library_browser.lua` | same mock-shape fix (1 occurrence) |
| `spec/test_main.lua` | same mock-shape fix (1 occurrence) |
| `spec/test_downloader.lua` | same mock-shape fix (2 occurrences) |
| `AGENTS.md` | Added KOReader-UI learning: "`Device.input.group.<Name>` is always a TABLE of key-name strings" |

## Verification

```
luajit spec/test_dashboard_widget.lua → 22 passed, 0 failed   (was 19 errors)
Full suite:                           → 577 passed, 0 failed  (now completely green)
```

`grep -rn 'group = { Back = "Back"' spec/` → 0 remaining; the correct shape
appears 9 times. The entire test suite is now green for the first time (the
dashboard suite was the last previously-failing one).

## Open Items & Next Steps

- [ ] **Commit** this fix (user triggers commits).
- [ ] None — the mock shape now matches KOReader; no production change needed.

---

*Log written by write-log skill*
