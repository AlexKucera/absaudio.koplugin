# Global position stored as seconds-from-start

Status: accepted

The manifest stores each book's playback position as a **single global scalar** (`current_time` in seconds from start of book), not as a `(track_index, position_in_track)` pair. This matches ABS's own `currentTime` field directly — sync push/pull is a simple scalar comparison with no conversion on the sync path. Playback converts global → track+offset when seeking via inkview (summing previous tracks' durations to find the right file and offset). The conversion cost is paid at seek-time only; the common path (sync every 60s) stays trivial.

Considered alternatives: `(track, offset)` would map directly to inkview's `PlayTrack(n)` / `SetTrackPosition(pos)` but would require round-trip conversion for every ABS sync operation. Since sync is the higher-frequency operation (every 60s during playback vs. seeks being user-initiated), we optimize for sync simplicity.
