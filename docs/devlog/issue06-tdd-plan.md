# Issue #6 TDD Plan: Playback Engine & Now-Playing UI

## Scenario: Position Conversion & Playback Controls

From PRD User Stories #23 (play immediately), #24 (resume from position), #25 (sequential multi-file playback), #26 (play/pause/skip/progress bar), #33 (auto-finish)

**Given** a downloaded audiobook with 3 audio tracks (durations: 300s, 240s, 280s = 820s total)
**When** the user taps Play on the book detail view
**Then** playback starts from position 0 (or stored current_time), the now-playing UI shows a play/pause button, ±30s skip buttons, a seekable progress bar, and current/total time — replacing nothing; inserted below cover art, above the existing download/delete section

---

## Architecture

### New files
- `absaudio/player.lua` — Player module with backend strategy pattern
  - Pure math: `global_to_track_offset()`, `track_offset_to_global()`
  - Backend interface: `InkviewBackend` (FFI, device) / `StubBackend` (emulator + tests)
  - State machine: stopped → playing → paused → stopped
  - Public API: `play()`, `pause()`, `resume()`, `stop()`, `close()`, `getPosition()`, `setPosition()`, `getDuration()`, `getCurrentTrack()`, `getPlaybackSpeed()`, `setPlaybackSpeed()`

### Modified files
- `absaudio/book_detail.lua` — Insert `_addNowPlaying()` section between cover art and metadata when audio is downloaded

### Test file
- `spec/test_player.lua` — All player tests

## TDD Slices (vertical order)

| Slice | Behavior | Tests |
|-------|----------|-------|
| 1 | global→(track,offset) position conversion math | ~8 tests |
| 2 | (track,offset)→global reverse conversion | ~6 tests |
| 3 | Player stub backend: create, state transitions | ~8 tests |
| 4 | Player stub: play/pause/stop/position tracking | ~10 tests |
| 5 | Player stub: seek/setPosition across track boundaries | ~6 tests |
| 6 | Player stub: multi-file sequential playback, auto-finish | ~5 tests |
| 7 | Playlist assembly from manifest audio files | ~4 tests |
| 8 | Now-playing UI: renders when audio downloaded | ~4 tests |
| 9 | Now-playing UI: controls are tappable (stub integration) | ~3 tests |

## UI Layout (inserted in BookDetailView:init())

```
┌─────────────────────────────┐
│ ← Back                     │
│                             │
│     [Cover Image]           │
│                             │
│  ┌─── Now Playing ───┐     │  ← NEW: _addNowPlaying()
│  │    ▶ / ❚❚         │     │
│  │  ⏪      ───●────  ⏩   │
│  │  0:00        13:40  │     │
│  └─────────────────────┘     │
│                             │
│  Title                      │
│  Author                     │
│  ⏱ 13h 40m                 │
│                             │
│  ✓ Audio downloaded         │  ← EXISTING: kept
│  🗑 Delete audio            │
│                             │
│  Audio Files                │
│  ...                        │
└─────────────────────────────┘
```
