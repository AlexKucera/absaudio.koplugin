# Issue #34 — Audio Slice C: TDD Plan + Device Handoff

> **Parent PRD:** #31 (In-App Audio Playback, FFmpeg + ALSA, Path C)
> **Slice:** C — first audible playback (tracer bullet)
> **This session:** off-device (Mac) control-flow layer behind injectable interfaces.
> **HITL remainder:** real FFmpeg decode + ALSA output + audible verification (device, PB700K3).

## Why this session builds control flow, not sound

Issue #34 is explicitly **HITL**: an unattended agent cannot hear the speaker or
drive the USB deploy/test loop. The PRD's Testing Decisions confirm the
device-dependent pieces (FFI loading, actual decode, audible output) cannot be
unit-tested. So this session TDD's the **off-device-testable control flow** with
every device call behind an injectable interface. The device session fills the
real bodies into those seams and verifies by ear.

## Modules + injection seams

| Module | Responsibility | Injectable seam (device fills this) |
|--------|----------------|-------------------------------------|
| `pcm_buffer.lua` (new) | Mutable PCM byte storage wrapping `ring_buffer` (the storage `ring_buffer` deliberately omitted). Shared by producer (write) + pump (read). | — (pure) |
| `audio_ffi.lua` (new) | Guarded FFmpeg/ALSA cdefs + real `is_available()` (dlopen libaudio-engine + key-symbol check, memoized). | `_set_probe_override(fn)` |
| `wake_lock.lua` (new) | Paired, idempotent acquire/release of the firmware sleep-ban. | `opts.impl = {acquire, release}` |
| `decode_producer.lua` (new) | Coroutine: open → decode frame → write buffer → yield on full/quota. `on_position(ms)` / `on_finished()` / `on_error(err)`. | `opts.decoder_factory(path)→decoder` |
| `output_pump.lua` (new) | `scheduleIn(0.05)` drain: read chunk → sink.write; backpressure resumes producer; underrun skips. | `opts.sink`, `opts.schedule`, `opts.producer` |
| `ffmpeg_backend.lua` (wired) | `play()`=acquire wake-lock + start producer + start pump; `stop()`/`close()`=tear all down + release; surface errors. | `opts.decoder_factory/sink/schedule/wake_impl` |

## Frozen interfaces (no drift between modules)

### pcm_buffer
```
pcm_buffer.new(capacity) -> buf
buf:capacity() buf:fill() buf:free() buf:empty() buf:full()
buf:can_write(n) buf:can_read(n)
buf:write(data_str)          -- copies bytes in at write_slot (wraparound); errors on overrun
buf:read(n) -> data_str      -- returns n bytes from read_slot; errors on underrun
buf:clear()
```

### decoder (the injected device interface)
```
decoder_factory(path) -> decoder | nil, err
decoder:read_frame() -> {pcm=<string>, pts_ms=<number>} | nil(EOF) | nil, err
decoder:close()
decoder:get_duration_ms() -> number
```

### sink / schedule / wake_impl (injected)
```
sink.write(data_str, n)
schedule(delay_seconds, fn) -> cancel_fn      -- default UIManager:scheduleIn
wake_impl.acquire() / wake_impl.release()
```

## Dual position source (keeps slice B green)
- No `decoder_factory` wired (slice B's 45 tests, emulator): clock model unchanged.
- `decoder_factory` wired (slice C integration tests, device): `producer.on_position(ms)`
  sets `position_ms = clamp(ms, duration)`; `getPosition` returns that.
- `producer_active` flag selects the source.

## Scenarios (BDD bridge — one per vertical slice)

From PRD #31 user stories 1, 6, 7, 26, 24:

1. **Producer feeds the buffer** (US 1, 10): Given a decoder that emits frames
   with advancing PTS, when the producer runs, then PCM bytes appear in the
   shared buffer and `on_position` fires with each frame's PTS.
2. **Producer yields on a full buffer** (US 4): Given a small buffer, when the
   producer fills it, then it yields (status `buffer_full`) and resumes only
   after the pump drains space.
3. **Producer signals EOF** (US 1, 22): Given a decoder that returns nil,
   when the producer reaches EOF, then `on_finished` fires and `is_done()` is true.
4. **Producer surfaces an undecodable file** (US 26): Given a decoder factory
   that errors, when the producer starts, then `on_error` fires with a clear
   message and the coroutine ends without crashing.
5. **Pump drains to the sink** (US 1): Given a fed buffer, when the pump ticks,
   then `sink.write` receives a chunk and the buffer's fill decreases.
6. **Pump applies backpressure** (US 4): Given a full buffer + a yielded
   producer, when the pump drains a chunk, then it resumes the producer.
7. **Pump survives underrun** (US 25): Given an empty buffer, when the pump
   ticks, then it skips the write (no crash) and keeps scheduled.
8. **Transport starts/stops the whole chain** (US 6, 7): Given an injected
   decoder+sink+wake-lock, when `play()` is called, then producer+pump+wake-lock
   all start; when `stop()` is called, all tear down and the wake-lock is released.
9. **Undecodable file does not crash the backend** (US 26): Given a failing
   decoder factory, when `play()` is called, then state ends `stopped`, a clear
   error is retrievable, and no exception escapes.
10. **Wake-lock pairs acquire/release** (US 7, 24): Given play then stop, then
    `impl.acquire` and `impl.release` are each called exactly once.

## Device handoff checklist (HITL — NOT this session)
- [ ] Confirm the `audio_ffi` cdefs match real symbols — shim loads without crashing on PB700K3; `is_available()` returns true.
- [ ] Fill the real FFmpeg open/find-stream/decode/resample body into the default `decoder_factory` (write PCM to a debug file first, NOT ALSA) — verify valid audio-shaped data.
- [ ] Fill the real ALSA body into `output_pump`'s default `sink` (`tts_sm` chain only; never `hw:0`).
- [ ] Confirm a short downloaded M4B plays audibly.
- [ ] Confirm wake-lock prevents suspend-stall during long playback; released on stop.
- [ ] Confirm stopping tears down producer + pump + wake-lock cleanly.

## Acceptance criteria status (issue #34)
- [ ] FFI shim loads; `is_available()` true on PB700K3 — **DEVICE**
- [ ] Decode producer writes valid PCM (debug dump) — **DEVICE**
- [ ] M4B plays audibly via `tts_sm` — **DEVICE**
- [x] No direct physical-codec access (output routed through `tts_sm` seam only) — **enforced by interface** (this session)
- [ ] Wake-lock held/released on device — **DEVICE** (logic + pairing tested off-device)
- [ ] Stopping tears down cleanly on device — **DEVICE** (teardown logic tested off-device)
- [x] Undecodable file → clear error, no crash — **off-device tested** (this session)
- [x] Emulator/tests still use stub backend (factory fallback unchanged) — **verified** (this session)
