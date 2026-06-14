# PRD: In-App Audio Playback (FFmpeg + ALSA, Path C)

This PRD covers real, in-app audiobook playback on the PocketBook Era Color
(PB700K3). It **supersedes the inkview-FFI playback assumption** in
`docs/prd/PRD.md` (stories 23–34) and in ADR-0002, which were written before the
on-device capability probes proved the firmware's public inkview audio API is
gutted and the internal `hw_*` player API is inaccessible to our process.

## Problem Statement

I can browse my Audiobookshelf library, download books, and open the dashboard
on my PocketBook Era Color — but when I press Play, **no sound comes out**. The
playback UI animates (play/pause icon, progress bar, time counter), but it is a
pure simulation: the plugin only ever runs a stub clock backend. There is no
audible audiobook playback, and therefore no real playhead to sync to ABS. The
native PocketBook player works fine, so the hardware can make sound — the plugin
just has no working decode+output path. I want to actually listen to my
downloaded books from inside the plugin, with my position syncing live to ABS so
my phone and my e-reader stay in step.

## Solution

Replace the stub playback with a real audio backend built on the device's own
FFmpeg/Libav decode stack and the firmware-managed ALSA `tts_sm` output path.
The backend decodes the downloaded M4B (AAC) to PCM in a Lua coroutine and plays
it back through the safe amplifier-managed audio chain, fully inside KOReader.
It owns the decode loop, so it computes the live playhead position itself and
can sync it to ABS as it plays. Transport (play/pause/stop), seek, and playback
speed are all in-app. The backend slots into the existing player strategy
alongside the stub (kept for emulator/tests), so no other module needs to know
how audio actually works.

## User Stories

### Core: audible playback
1. As a listener, when I tap Play on a downloaded audiobook, I want to hear it
   through the device's speaker (or headphones) — not just see the UI animate —
   so I can actually listen.
2. As a listener, I want playback to start within a second or two of tapping
   Play, so it feels responsive.
3. As a listener, I want playback to continue even when I leave the plugin
   (background audio), so I can listen while reading an ebook in KOReader.
4. As a listener, I want reliable playback without dropouts, glitches, or the
   event loop freezing the rest of KOReader.
5. As a listener, I want the plugin to never corrupt the device's amplifier —
   audio must go through the firmware-managed path, not direct codec access.

### Transport
6. As a listener, I want a play/pause button that actually starts and pauses
   real audio, so the UI state matches reality.
7. As a listener, I want to stop playback cleanly so it doesn't leave audio
   resources held or the device awake.
8. As a listener who paused, I want Resume to continue from the exact spot, not
   restart or jump.
9. As a listener who closes the book and reopens it, I want playback to resume
   from my last position.

### Position & seeking
10. As a listener, I want the time display and progress bar to reflect the real
    audio position as it plays, advancing smoothly.
11. As a listener, I want to tap a seekable progress bar to jump to a position
    in the book.
12. As a listener, I want skip-backward / skip-forward 30s buttons that move
    real audio position.
13. As a listener, I want the plugin's reported position to match the native
    PocketBook player's position for the same file, so switching between them
    doesn't jump my place.

### Chapters & multi-file books
14. As a listener, I want the current chapter name shown during playback,
    reflecting where I am in the book's structure.
15. As a listener, I want to tap a chapter in the list to seek directly to its
    start.
16. As a listener, I want next/previous chapter skip controls that jump to
    chapter boundaries.
17. As a listener with a multi-part audiobook (multiple audio files), I want the
    parts to play seamlessly in sequence as one book, with a single global
    position across all parts.

### Playback speed
18. As a listener who prefers faster listening, I want to cycle through speed
    presets (0.5×–2×) with a single tap and hear audio at that speed.
19. As a listener, I want my chosen speed remembered as a local preference and
    applied on resume, without affecting the position value synced to ABS.

### Sync (the reason this PRD exists)
20. As a listener who started a book on my phone this morning, I want the
    plugin to pull the latest position from ABS when I start playing, so I
    resume at the right spot.
21. As a listener playing on the e-reader, I want my position pushed to ABS
    periodically while audio plays, so my phone stays in step (live sync, not
    just on-close).
22. As a listener who finishes a book, I want it auto-marked finished locally
    and synced to ABS.
23. As a listener offline, I want playback to work from my last local position
    and sync silently deferred until I'm back online.

### Reliability on the device
24. As a listener, I want playback to keep going when the device would otherwise
    auto-suspend, so a long book doesn't stall until I tap the screen.
25. As a listener whose decode can't keep up or whose output underruns, I want
    graceful behavior (skip/gap/recover) rather than a crash or a frozen UI.
26. As a listener whose audio file is corrupt or undecodable, I want a clear
    error message, not a silent failure or a crash.
27. As a developer/debugger, I want a safe on-device probe (the existing "Audio
    diagnostics" menu item) to confirm capabilities and capture failures, since
    there is no terminal or SSH on this device.

## Implementation Decisions

### Why not the obvious options (decided by on-device probing)
The Era Color's firmware was probed across five iterations on the device:
- The **public inkview audio API** (`PlayFile`, `GetTrackPosition`,
  `SetPlayerState`, `LoadPlaylist`, `GetPlaybackSpeed`) is **not exported** on
  this firmware — only `OpenPlayer`, `TogglePlaying`, and volume remain.
- The firmware's **internal `hw_*` player API** (`hw_mp_setstate`,
  `hw_is_audio_book_playing`, volume) is callable, but `GetAudioPlayingInfo`
  returns NULL for our process — the position/duration struct is only populated
  for the process that owns the registered player (`bookshelf.app`). So a backend
  on top of the inkview player API **cannot read the live playhead** and therefore
  cannot do live sync.
- There are **no external player binaries** (no ffmpeg/mpv/aplay) on the stock
  device.

What the device *does* have: `libaudio-engine.so` (a decode + ALSA-output
toolkit exporting full FFmpeg and an ALSA output helper), `libavcodec.so` 6.0
with the AAC decoder, and a firmware-managed ALSA `tts_sm` softvol → Loopback →
codec chain that handles amplifier power safely (direct codec access can
corrupt this device's amplifier).

### The chosen architecture: decoupled decode + output ring buffer
Audio is produced and consumed by **two independent loops** coordinated through a
fixed-size PCM ring buffer, rather than one loop doing both. This mirrors the
proven coroutine + scheduled-pump pattern already used for downloads in this
codebase (ADR-0005), and avoids the event-loop starvation that a single coupled
loop would re-introduce.

**Decode producer** — a Lua coroutine that performs the FFmpeg decode pipeline:
open the file, find the best audio stream, open the AAC decoder, optionally
attach a speed (`atempo`) filter graph, decode frame-by-frame, resample to a
fixed PCM format (S16LE, 48 kHz, stereo), and write PCM into the ring buffer.
It computes the playhead position itself, frame by frame, from each packet's
presentation timestamp. It never yields inside a C call; it yields between
frames when the buffer is full.

**Output consumer** — a short scheduled task (the existing ~50 ms pump cadence)
that drains the ring buffer to the ALSA output device, applies backpressure to
the producer when full, and waits when empty (underrun). It resumes the decode
coroutine to keep the buffer fed.

**Why this shape:** every FFmpeg and ALSA symbol it needs is confirmed present
on the device (no reverse-engineering unknowns, unlike the discarded opaque-
handle API); it keeps blocking C work out of the UI event loop; and position is
computed by code we own, so live ABS sync is guaranteed. The split also lets the
decode half be swapped later for the device's opaque-handle engine without
touching output, position, or sync.

### Module breakdown

**New — FFmpeg audio backend** (a deep module). It exposes the **same backend
contract** the other backends already implement (`play`, `pause`, `resume`,
`stop`, `close`, `getPosition` → seconds, `setPosition(seconds)`,
`getDuration` → seconds, `getPlaybackSpeed` / `setPlaybackSpeed`,
`isFinished`, `getState`), so the rest of the plugin is unaware how audio is
actually produced. Its internals (the producer/consumer/ring/FFI-shim split,
the FFmpeg lifecycle, ALSA buffer handling, the millisecond↔second conversions)
are fully hidden. It also exposes an `is_available()` capability probe used for
backend selection.

Inside it, a pure **position-math layer** (no FFI) handles: converting between
FFmpeg time-base fractions and seconds/milliseconds (the `av_rescale_q`-style
arithmetic), ring-buffer index math (advance, fill level, wraparound,
overrun/underrun), and building the `atempo` filter-chain string for arbitrary
speeds.

**Modified — player factory.** The factory that builds a player from a manifest
entry today hardcodes the stub backend; it will instead auto-select the FFmpeg
backend on a real device (via the capability probe) and keep the stub for the
emulator and tests. The inkview backend remains as dead-but-harmless legacy.
This change is confined to backend selection — the player's public API and all
its callers are unchanged.

**Modified — book detail view.** The "now playing" UI currently drives the stub.
It is rewired to the real backend's transport methods and to polling the real
position every ~0.5 s (the polling cadence and partial-refresh rendering
behavior already exist and stay). Existing features layered on position —
chapter display/navigation, skip-30s, seek-to-chapter, speed badge, the
finishing-on-completion behavior — work unchanged because they already operate
on the abstract position the backend reports.

### Position is computed by the decode loop
Because the backend owns decoding, the live position comes directly from the
audio data:

`position_ms = rescale(current_packet.pts, stream.time_base, {1, 1000})`

This is the single decision that makes live sync possible without reading any
device-specific player state. Global position (seconds, ABS-compatible scalar,
per ADR-0001) is derived across playlist parts by summing prior-track durations
(ADR-0002's playlist model) — the existing global↔track math is reused
unchanged.

### Safe output path
PCM is written to the ALSA device named `tts_sm`, whose firmware config chains
`softvol → dmix → hw:Loopback,0`, with a firmware `alsaloop` bridging to the
physical codec — the path the firmware intends, which manages amplifier power.
The implementation tries the device's bundled audio-engine toolkit output
helpers first (purpose-built, likely amplifier-aware) and falls back to raw ALSA
`snd_pcm_writei` on `tts_sm`. It never opens the physical codec device directly.

### Wake-lock during playback
PocketBook auto-suspend can stall the scheduled output pump until an input event
wakes the device (a real failure mode observed this session). For the duration
of active playback the backend holds a wake-lock (the firmware's sleep-ban
mechanism), releasing it on pause/stop/close. This is what makes long unattended
playback reliable.

### Backend selection and fallback
On a real device, the FFmpeg backend is selected when its capability probe
succeeds (libraries load and key symbols resolve). If it is unavailable, the
player falls back to the stub so the UI still renders (clearly a degraded state
rather than a crash) — and, as a future option, an `OpenBook` handoff to the
native player could offer a guaranteed-working fallback with sync-on-return
only.

### ADR impact
This work supersedes the inkview-FFI playback assumption in ADR-0002 and the
original PRD's playback section. A new ADR should record the path C decision and
the decoupled decode/output shape. ADR-0001 (global position in manifest),
ADR-0002 (playlist model), ADR-0003 (furthest-wins sync), and ADR-0005
(coroutine pattern) all remain valid and are built upon unchanged.

## Testing Decisions

### What makes a good test
Tests verify external behavior, not implementation details. The pure,
device-independent pieces are unit-tested on the development machine with
`busted` (the project's existing test runner and mock framework). The
device-dependent pieces (FFI loading, actual decode, audible output) cannot be
unit-tested and are validated manually on the PB700K3 via the existing "Audio
diagnostics" probe and by ear.

### Modules to be tested (on the Mac, no device)
- **Position/duration math** — time-base → seconds/milliseconds conversion, the
  `rescale`-style arithmetic at boundaries (zero, beyond-stream-end, fractional
  time bases), millisecond↔second round-tripping. Pure.
- **Ring-buffer index math** — advance, fill level, wraparound, and overrun/
  underrun detection across a range of buffer sizes and chunk sizes. Pure.
- **`atempo` filter-chain string builder** — produces a valid filter chain for
  the full preset range (0.5×–2×) including chaining multiple `atempo` stages
  for values outside a single stage's range. Pure.
- **Backend contract conformance** — the new backend satisfies the same
  transport state-transition table already proven against the stub and inkview
  backends (play/pause/resume/stop lifecycle, `getPosition`/`isFinished` edge
  cases, speed get/set), with the FFI layer stubbed out so no device is needed.

### Device-only (manual validation on the PB700K3)
FFI symbol availability, actual AAC decode, resample, audible output via
`tts_sm`, seek/speed behavior under real playback, wake-lock preventing
suspend-stall, and live position accuracy against the native player.

### Prior art for tests
The project already tests the stub and inkview backends and the pure
global↔track-offset math under `spec/` using a shared mock framework. The new
backend's contract-conformance tests mirror those exactly; the new pure-math
tests follow the same assertion style as the existing navigator and config
tests.

## Out of Scope

- Multi-device support (Kobo, Android, Kindle) — PocketBook Era Color only.
- Immersion reading / synced text highlighting — background audio only.
- Sleep timer (exists in the UI plan; delivered by a separate effort, reusing
  the real `pause()` this PRD provides).
- Equalizer / tone controls beyond playback speed.
- Gapless playback between playlist parts (seamless *continuation* is in scope;
  sample-accurate gapless joins are not).
- Replacing the inkview backend's source (kept as harmless legacy).
- Bundling or cross-compiling FFmpeg binaries — the device's own system
  libraries are used.
- Automatic native-player handoff as a primary path (noted only as a future
  fallback option).

## Further Notes

### Probe findings (the evidence base)
The five on-device probe iterations that established what the Era Color can and
cannot do are captured in full in
`docs/devlog/20260614-decision-audio-backend-path-c-ffmpeg_log.md`, including
the complete exported-symbol lists for `libaudio-engine.so`, `libavcodec.so`,
and `libinkview.so`, and the ALSA `tts_sm`/Loopback chain from `/etc/asound.conf`.
That document is the authoritative reference for the "why not the other paths"
decisions above.

### No terminal / SSH on the device
The `terminal.koplugin` fails (`/dev/ptmx` unavailable) and `dropbear` won't
start. All on-device debugging goes through the plugin's own menu and the
`absaudio/audio_probe.lua` diagnostic module (wired as the "Audio diagnostics"
menu item). That probe and menu item should be retained until playback ships,
then removed.

### Implementation sequencing (for whoever picks this up)
Ordered so the bulk is Mac-testable first and the slow device-feedback work is
last: (1) position/ring/atempo pure math [Mac, TDD]; (2) backend contract
conformance with FFI stubbed [Mac, TDD]; (3) FFI cdef shim + availability probe
[device]; (4) decode producer verified against a debug PCM file, not ALSA
[device]; (5) output consumer → first audible playback [device]; (6) transport
+ seek + speed wired into the detail view [device]; (7) live ABS sync
integration [device + server].

### Open questions to resolve on-device during later slices
- Whether the device's bundled audio-engine output helpers (`open_alsa` /
  `push_output_buffer`) are amplifier-aware and preferable to raw `snd_pcm_writei`
  on `tts_sm`.
- Whether a single LuaJIT coroutine decode loop sustains realtime AAC at 1× and
  at 2× (audio decode is light; expected yes, but confirm before optimizing).
- The exact wake-lock mechanism that cleanly integrates with KOReader's existing
  power management.
