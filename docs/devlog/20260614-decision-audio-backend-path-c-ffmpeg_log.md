# Decision: In-App Audio Backend = Path C (FFmpeg + ALSA, Design 3)

> **Date:** 2026-06-14
> **Type:** decision / design
> **Reference:** concludes the three-issue device session (flashing #1, no-audio #2, file-location #3, plus dashboard-escape and library-crash fixes)

## Goal

Decide the architecture for real, in-app audiobook playback on the PocketBook
PB700K3, with **live playhead sync** to an Audiobookshelf server. This is the
handoff document for the implementation work (multi-session build).

## Context — how we got here (read this first)

Five probe iterations on the PB700K3 (firmware U700k3.6.10.2359) mapped the
device's audio capabilities:

- **`libinkview.so` public API (`inkview.h`):** gutted on this firmware. Only
  `OpenPlayer`, `TogglePlaying`, `SetVolume`/`GetVolume` are exported. `PlayFile`,
  `GetTrackPosition`, `SetPlayerState`, `GetPlaybackSpeed` — **all absent**.
- **`libinkview.so` internal `hw_*` API (discovered via v4 ELF scan):** real and
  callable — `hw_mp_setstate`, `hw_is_audio_book_playing`, `hw_mp_getvolume`,
  `GetVolume`/`SetVolume`. BUT `GetAudioPlayingInfo(buf)` **returns NULL and
  zero-fills the buffer for our process** (v5 probe), because the struct is only
  populated for the process that *owns* the registered player (`bookshelf.app`).
  → **Path B (inkview hw_mp backend) is DEAD** — no live position read.
- **`libaudio-engine.so` (140 exports):** a **decode + ALSA-output toolkit**, not a
  complete player. Exposes `AudioEngine_CreateAudioEngine`/`CreatePlayer`/
  `DestroyPlayer` (opaque handles), full FFmpeg (`avformat_open_input`,
  `av_read_frame`, `av_seek_frame`, `avcodec_send_packet`/`receive_frame`,
  `avfilter_*`), ALSA output (`open_alsa`/`open_alsa_ex`, `push_output_buffer`,
  `get_output_buffer`, `alsa_output_working`, `init`/`deinit_alsa_output`,
  `pause_alsa`), ALSA mixer, and its own `pthread_create` (owns a thread).
  The player *transport state machine* lives in the caller (`bookshelf.app`), not
  this library.
- **`libavcodec.so.60` (580 exports):** FFmpeg 6.0; AAC decoder present
  (`avcodec_find_decoder`); `swr_init` (resample); `lame_init` (MP3 enc). m4b is
  fully decodable.
- **Safe output path:** `/etc/asound.conf` defines `tts_sm` softvol → `hwout_mix`
  dmix → `hw:Loopback,0,0`; firmware `alsaloop` reads `hw:Loopback,1` → physical
  codec. Writing to `tts_sm` routes through firmware-managed amplifier control
  (**safe** — direct `hw:0` access can corrupt the PB700K3 amplifier).
- **No external audio binaries:** no ffmpeg/mpv/aplay/mplayer on the stock device.
- **No terminal/SSH:** the `terminal.koplugin` fails (`/dev/ptmx` unavailable);
  dropbear won't start. All on-device work goes through the plugin's own menu +
  a diagnostic probe module (`absaudio/audio_probe.lua`).

## The three designs considered

1. **Pure-Lua coroutine decode loop** — one coroutine drives FFmpeg frame-by-frame
   and writes PCM to ALSA in the same loop. Simplest, but couples decode to
   output: a full ALSA buffer blocks the decode coroutine inside a C call, and
   the single loop re-hits the event-loop starvation class of bug already debugged
   twice this session (downloads). **Rejected.**

2. **`libaudio-engine.so` `AudioEngine_CreatePlayer` (C-owned thread)** — opaque
   handle owns decode+output; Lua calls transport. Hides the most, writes the
   least Lua — but rests on **unknown argument types** (`CreatePlayer` takes a
   path? a struct?). That's the same high-risk reverse-engineering bet that path B
   just lost (`GetAudioPlayingInfo` returned NULL). **Rejected** as the primary;
   left open as a future optimization if the handle API ever gets documented.

3. **Decoupled decode + output ring buffer (CHOSEN)** — a decode coroutine
   (blocking FFmpeg, no yield inside C) fills a Lua-side PCM ring buffer; a
   separate `scheduleIn` pump drains it to ALSA. Position tracked in the decode
   loop from `av_rescale_q(pkt.pts)`; seek = reopen at offset; speed = `avfilter`
   `atempo`. **Zero unknowns** (all symbols confirmed) and reuses the exact
   coroutine + `scheduleIn` pump pattern already proven in this codebase
   (`chunked_http.lua` + the download pump in `book_detail.lua`).

## The decision

**Build path C using Design 3 (decoupled decode + output ring buffer).**

Rationale: it is the only shape with no reverse-engineering unknowns and no
starvation risk, and it fits the codebase's existing conventions. Design 2 stays
open as a later swap for the decode half (the split makes it cheap to replace the
producer without touching output/pump/sync).

## Interface sketch (for the implementing session)

The new module — say `absaudio/ffmpeg_backend.lua` — implements the **same
backend contract** as `stub_backend.lua` / `inkview_backend.lua` (so it drops
into the existing `player.create()` strategy): `new(opts)`, `play()`, `pause()`,
`resume()`, `stop()`, `close()`, `getPosition()`, `setPosition(sec)`,
`getDuration()`, `getPlaybackSpeed()`, `setPlaybackSpeed()`, `isFinished()`,
`getState()`. `player.create_from_manifest()` selects it when on-device
(extend the `backend` option: auto-detect via `inkview_backend.is_available()`
or a new `ffmpeg_backend.is_available()`).

Internal decomposition (Design 3):
- **Decode producer** (coroutine): owns the FFmpeg state machine
  (`avformat_open_input` → `avformat_find_stream_info` → `av_find_best_stream` →
  `avcodec_open2` → `av_read_frame`/`send_packet`/`receive_frame` → optional
  `avfilter` atempo graph → `swr_*` resample to S16LE/48k/stereo). Writes PCM
  into a fixed-size Lua ring buffer; yields when the buffer is full or every N
  frames. Computes `position = av_rescale_q(pkt.pts, stream.time_base, {1,1000})`
  in ms each frame.
- **Output consumer** (scheduleIn pump, ~0.05s): drains the ring to ALSA via
  `push_output_buffer` / `snd_pcm_writei` (route through `tts_sm`). Handles
  underrun (buffer empty → wait) and overrun (buffer full → backpressure to
  producer). Drives the decode coroutine via `coroutine.resume`.
- **FFI layer:** cdefs for all used FFmpeg + ALSA functions (validated against
  v4 export list). Keep cdefs minimal and guarded (`pcall`) — a missing symbol
  must not crash (lesson from the `IsPlayingMP3` probe crash).

## Implementation plan (slices, TDD-able units first)

Ordered so the bulk is unit-testable on the Mac (no device) and the slow
device-feedback work is last:

1. **Pure position/duration math** (Mac, TDD): `av_rescale_q` wrapper behavior
   (ms↔s, stream time-base fractions), ring-buffer index math (advance, fill
   level, wraparound), speed→atempo filter-chain string (reuse the pattern from
   stradichenko's `mediaengine.lua:_atempoFilterString`). No FFI. Slice this first.
2. **Backend contract conformance** (Mac, TDD): the new backend satisfies the
   same table of state transitions the stub/inkview tests already cover
   (`spec/test_player.lua`) — adapt the existing player tests to run against the
   ffmpeg backend with the FFI layer stubbed.
3. **FFI cdef shim + availability probe** (device): declare the FFmpeg/ALSA
   cdefs (guarded), implement `is_available()` (dlopen + check a few key
   symbols). Deploy, confirm the shim loads without crashing on the PB700K3.
4. **Decode producer** (device): wire FFmpeg open/decode/resample; verify it
   produces PCM (write to a debug file first, NOT to ALSA) for the test m4b.
   Confirm duration + position read.
5. **Output consumer** (device): open `tts_sm` (or the libaudio-engine
   `open_alsa`), drain ring → PCM, confirm audible playback (the moment of
   truth). Start with a short clip.
6. **Transport + seek + speed** (device): play/pause/resume/stop, seek via
   reopen-at-offset, speed via atempo graph. Integrate position polling into
   `book_detail.lua`.
7. **ABS sync integration** (device + server): push live position to ABS on the
   existing sync cadence; resume from server position.

## Open questions to resolve during slices 3–5 (device)

- **Output device name:** `tts_sm` (raw ALSA via `snd_pcm_open`) vs
  `libaudio-engine.so`'s `open_alsa`/`push_output_buffer` (which may already be
  wired to the right device). Try the libaudio-engine toolkit first — it's
  purpose-built and likely handles the amplifier wake correctly.
- **Decode performance:** can a single LuaJIT-coroutine decode loop keep up with
  realtime AAC? Likely yes (audio decode is light), but confirm before adding
  speed/pitch. If not, Design 2's C-thread becomes the fallback.
- **`open_alsa_ex` vs `open_alsa`:** unknown difference; probe at runtime.

## Lessons from this session (apply during implementation)

- LuaJIT: declare **all** symbols in `cdef` before indexing a lib namespace;
  access undefined symbols throws uncaught ("undefined symbol") → wrap lookups
  in `pcall`. NULL cdata is truthy and `== nil` is unreliable → test via
  `tonumber(ffi.cast("uintptr_t", p)) == 0`.
- Event loop: `scheduleIn(0)` starves `UIManager:handleInput()`; use
  `scheduleIn(0.05)`. PocketBook auto-suspend can stall idle timers — acquire a
  wake-lock (inkview `BanSleep` / `hw_ban_suspend`) for the download/playback
  duration if stalls appear.
- Every meaningful change needs a DOX pass + devlog; existing patterns (stub /
  inkview backend, download pump) are the reference contracts.
- The probe module (`absaudio/audio_probe.lua`) + the absaudio-menu "Audio
  diagnostics" item are the on-device feedback loop; keep them until playback
  ships, then remove the menu item.

## Files to touch (planned)

- `absaudio/ffmpeg_backend.lua` (new)
- `absaudio/player.lua` (extend `create_from_manifest` backend selection)
- `spec/test_ffmpeg_backend.lua` / `spec/test_player.lua` (new/updated)
- `absaudio/book_detail.lua` (position polling + transport wiring)
- `absaudio/audio_probe.lua` (keep as tripwire until playback ships)
- `docs/devlog/` (per-slice logs)
