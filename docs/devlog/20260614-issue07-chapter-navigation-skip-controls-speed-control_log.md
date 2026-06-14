# Issue #7 / Slice 6: Chapter Navigation + Skip Controls + Speed Control

> **Date:** 2026-06-14
> **Type:** issue
> **Reference:** [GitHub #7 — Slice 6](https://github.com/AlexKucera/absaudio.koplugin/issues/7) (parent #1; blocked by #6 playback engine)

## Goal

Deliver chapter navigation, chapter skip controls, and playback speed control, building on the slice-5 playback engine. Concretely: a Chapter Navigator pure-logic module (position ↔ chapter mapping), current-chapter name display below the progress bar, a tappable chapter list that seeks to a chapter's start, next/prev chapter skip buttons, and a tap-to-cycle playback speed control with local-only persistence (default 1×). All chapter/speed logic must be pure functions testable without hardware. Covers user stories US 27–30.

## What Was Done

- **New module `absaudio/chapter_navigator.lua`** — zero-dependency pure logic (no FFI, no KOReader globals, no I/O). Public API:
  - `current(pos, chapters)` → `(index, chapter)`; half-open `[start,end)` convention (boundary belongs to the LATER chapter); beyond-last clamps to last; empty/nil → `(0,nil)`
  - `next(pos, chapters)` → next chapter, or `(nil,nil)` at last
  - `previous(pos, chapters, opts)` → smart restart: deep in chapter (> `opts.threshold`, default 10s) restarts CURRENT; near start → previous chapter, clamped to first
  - `chapter_start(index, chapters)` → seek-target seconds (clamps index)
- **`absaudio/player.lua`** — two pure helpers added:
  - `player.next_speed(s)` cycles `{0.5,0.75,1.0,1.25,1.5,1.75,2.0}` and wraps; unknown/nil treated as 1× base → next is 1.25
  - `player.format_speed(s)` renders compact badge (`1×`, `1.5×`, `0.75×`, `2×`); nil → `1×`
- **`config.lua`** — added `playback_speed = 1.0` to `DEFAULTS`.
- **`absaudio/book_detail.lua`** — UI wiring:
  - Required `chapter_navigator`
  - `_initPlayer` applies persisted speed on player creation (nil-guarded)
  - `_addNowPlaying`: captures `self.chapters` from `item.media.chapters`; adds chapter-name widget below the progress bar (centered, grey); adds a ⏮ / centered-speed-badge / ⏭ row; chapter buttons hidden when no chapters (speed badge shown centered alone)
  - 4 new handlers: `_onChapterPrev`, `_onChapterNext`, `_onSpeedCycle`, `_onSeekToChapter`
  - `_updatePlaybackDisplay` now refreshes the chapter-name widget live (with `:free()` cache invalidation)
  - `_addChapters` chapter-row tap handler wired to `_onSeekToChapter(idx)` (replaced the previous InfoMessage stub)
  - `_onSpeedCycle` persists via `config.set("playback_speed", …)` + `:flush()` and updates the badge immediately (`:free()` before repaint)
- **Refactor** — `_onChapterPrev`/`_onChapterNext` delegate to `_onSeekToChapter` (eliminated duplicated seek+update logic)
- **DOX pass** — documented `chapter_navigator` responsibility in `absaudio/AGENTS.md`; added `test_chapter_navigator.lua` to `spec/AGENTS.md`
- **44 new tests, all green**: `test_chapter_navigator` (30, new), `test_player` (+4 = 79), `test_config` (+2 = 14), `test_book_detail` (+8 = 51)

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Two skip rows layout (keep ±30s; add ⏮/⏭ + speed badge on a second row) | User-selected option. Keeps both fine-grained ±30s seek AND coarse chapter skip; cleanest e-ink readability. |
| Smart restart for prev-chapter | User-selected option. If >10s into current chapter, prev restarts it; near start → previous. Avoids the "5s in, hit prev, now way back in ch2" problem. Standard audiobook UX. |
| Half-open `[start,end)` boundary (boundary belongs to LATER chapter) | Matches "I just reached chapter N". A position at exactly ch[i].end == ch[i+1].start is treated as being in ch[i+1]. Documented in module header + tested. |
| `chapter_navigator` as a zero-dependency pure module | Deepest possible module (small interface, deep implementation). PRD §Testing Decisions flags chapter navigator as Medium-priority pure logic — no FFI/IO means fully unit-testable. |
| 10s default smart-restart threshold (overridable via `opts.threshold`) | Tunable constant; sensible default that distinguishes "just started" from "settled in". |
| Speed persisted locally via `config`, NOT synced to ABS | PRD §Playback Speed: "position scalar remains consistent regardless of speed on either device." Default 1×. |
| `next_speed` normalizes unknown/nil to 1× base | Defensive: an unknown persisted value (manual edit, schema drift) cycles forward from 1× rather than crashing or stalling. |
| Refactor prev/next handlers to delegate to `_onSeekToChapter` | DRY — all three perform "seek to chapter start + refresh display". Single source of truth for the seek path. |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| Test fixtures crash: `unexpected symbol near 'end'` | `end` is a Lua reserved keyword — cannot use as a table key literal `{ end = 600 }` | Use `["end"] = 600` (matches how `book_detail.lua` already reads `chapter["end"]`) |
| `set_line` edit on `_initPlayer` duplicated the function body (left original lines below), then caused `<eof>` expected / `end` expected parse errors | `set_line` replaced only ONE line; the surrounding `end`s got out of balance when I added the speed-apply block | Read fresh anchors, removed the duplicated lines, re-counted `end`s (need 2 closes for nested `if` + function) |
| Regression: `_addDownloadStatus` test fails: "attempt to index field 'player' (a nil value)" | My new `_initPlayer` code indexed `self.player.setPlaybackSpeed` but `create_from_manifest` can return nil (downloaded-but-not-playable / test scenarios) | Added nil guard: `if has_config and self.player then …` |
| Speed handler test fails: "attempt to call field 'set' (a nil value)" | The test's mock `config` only stubbed `get`; my new persistence code calls `config.set` + `config.get_settings().flush()` | Extended the mock config to provide `set`, `get_settings` (with no-op `flush`), and a `mock_playback_speed` variable reset per test |
| Initial-badge test flaky across tests (speed leaked between cases) | `mock_playback_speed` mutated by `_onSpeedCycle` persisted into the next view build | Reset `mock_playback_speed = 1.0` at the top of `make_chapter_view` helper |
| GitNexus MCP impact/detect-changes tools error: "LadybugDB unavailable … Database file version: 41, Current build storage version: 40" | The `npx gitnexus analyze` rebuild wrote a v41 DB file while the MCP server's reader expects v40 | Environment issue, not fixable from session. CLI index is current (728 nodes). Verified blast-radius manually: all changes contained to `book_detail.lua` private methods + a new zero-caller module + pure-function additions. |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/chapter_navigator.lua` | **NEW** — pure-logic position↔chapter mapping: `current`, `next`, `previous` (smart restart), `chapter_start` |
| `absaudio/player.lua` | +`next_speed()` (cycles 7 presets, wraps) + `format_speed()` (compact badge) |
| `config.lua` | +`playback_speed = 1.0` default |
| `absaudio/book_detail.lua` | Chapter-name widget, ⏮/⏭+speed row, 4 handlers (`_onChapterPrev/_onChapterNext/_onSpeedCycle/_onSeekToChapter`), live chapter label refresh, chapter-tap→seek, persisted-speed apply on init |
| `spec/test_chapter_navigator.lua` | **NEW** — 30 tests (boundaries, beyond-last, single/empty chapters, smart restart, round-trip) |
| `spec/test_player.lua` | +4 tests (speed cycle/wrap, format) |
| `spec/test_config.lua` | +2 tests (default + round-trip persistence) |
| `spec/test_book_detail.lua` | +8 tests (chapter nav handlers, speed badge, no-chapters fallback); extended mock config with `set`/`get_settings` |
| `absaudio/AGENTS.md` | DOX: documented chapter_navigator module responsibility |
| `spec/AGENTS.md` | DOX: added test_chapter_navigator.lua to ownership list |

## Acceptance Criteria

| # | Criterion | Status |
|---|-----------|--------|
| 1 | Chapter navigator returns correct current chapter for any global position | ✅ |
| 2 | Current chapter name displayed below progress bar during playback | ✅ |
| 3 | Chapter list shown in now-playing/detail view, tappable for seek-to-chapter | ✅ |
| 4 | Next/prev chapter skip buttons jump between chapter boundaries | ✅ (smart restart) |
| 5 | Speed button cycles through 0.5×–2× | ✅ |
| 6 | Current speed displayed as badge on speed button | ✅ |
| 7 | Speed change takes effect immediately during playback | ✅ |
| 8 | Speed preference persisted locally across sessions (default 1×) | ✅ |
| 9 | Unit tests pass for: position at exact chapter start/end, beyond last, single-chapter, empty chapters | ✅ |
| 10 | Chapter + speed UI work in emulator with stub player backend | ⏳ needs manual `./kodev run` |
| 11 | Actual speed-change audio output verified on PocketBook hardware | ⏳ needs hardware |

## Open Items & Next Steps

- [ ] Verify chapter UI + speed control in KOReader emulator (`./kodev run`): chapter label updates live, ⏮/⏭ seek correctly, chapter-list tap seeks, speed badge cycles + persists across plugin restart, no-chapter book hides chapter buttons
- [ ] Verify actual audio tempo change on PocketBook with inkview backend (acceptance #11)
- [ ] Pre-existing test failures (unrelated to this slice, confirmed failing on original code): `test_api.lua` (crashes/no summary) and `test_library_browser.lua` (InfoMessage nil at library_browser.lua:741)
- [ ] GitNexus MCP DB version skew (v41 file vs v40 reader) — environment issue; CLI index is current but impact/detect-changes MCP tools are unavailable until resolved
- [ ] Consider `IconWidget` for ⏮/⏭ glyphs if TextWidget rendering is inconsistent on device (consistent with the open item from the 06-14 playback-UI fix)

---

*Log written by write-log skill*
