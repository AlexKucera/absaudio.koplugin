# Fix: Cancel download hangs emulator until download completes

> **Date:** 2026-06-10
> **Type:** issue
> **Reference:** Bug report — cancelling a download does not work, emulator hangs until download is done

## Goal

Fix the cancel button on the download progress widget so that tapping it actually stops the download instead of hanging the emulator until the download completes naturally.

## What Was Done

- Diagnosed root cause: `UIManager:scheduleIn(0, pump)` in the download pump loop starves KOReader's input event processing
- Changed three `scheduleIn(0, ...)` calls to `scheduleIn(0.05, ...)` in `absaudio/library_browser.lua` (lines 800, 814, 821)
- Added explanatory comments at each call site explaining why 0-delay is dangerous
- Added two new learnings to `AGENTS.md`: the `scheduleIn(0)` footgun, and socket-read-blocking coroutines

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Use `scheduleIn(0.05, pump)` (50ms) instead of `scheduleIn(0, pump)` | `UIManager:handleInput()` drains ALL due tasks in a `repeat…until` loop before processing input events. `scheduleIn(0)` makes tasks "due now" (`time.now() + 0`), so each pump reschedules itself as immediately due, keeping the drain loop spinning forever. 50ms lets the drain loop exit and input events process, while still pumping ~20 chunks/sec for responsive progress UI. |
| Fixed all three `scheduleIn(0)` calls, not just the pump loop | The `schedule_next` and initial pump start calls had the same issue — even if they run once, they block the event loop for one full drain cycle unnecessarily. |
| No test changes needed | Existing `start_chunked_download` tests already verify cancel logic at the coroutine level. The bug was in the UIManager scheduling layer, which isn't unit-testable without a full UIManager mock. |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| Cancel button tap ignored during download | `UIManager:scheduleIn(0, pump)` makes each pump task "due now". UIManager's `handleInput()` has a `repeat…until not self._task_queue_dirty` loop that drains all due tasks before calling `Input:waitEvent()`. Each pump reschedules itself with delay 0, so `_task_queue_dirty` stays true and the loop never exits — input events are never processed. | Changed to `scheduleIn(0.05, pump)`. The 50ms delay puts the next pump slightly in the future, so the drain loop exits, repaint runs, and `Input:waitEvent()` processes queued tap/gesture events. |
| Initial diagnosis took time — multiple plausible hypotheses | The coroutine/pump architecture *looks* correct in isolation (yield between chunks, check cancel flag). The bug is in the interaction with UIManager's event loop, not in the coroutine logic itself. | Read KOReader's `uimanager.lua` source to understand `_checkTasks()` drain loop and `_task_queue_dirty` flag. Traced the full path: `handleInput()` → `_checkTasks()` → `repeat…until` → `Input:waitEvent()`. |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/library_browser.lua` | Changed 3× `scheduleIn(0, ...)` → `scheduleIn(0.05, ...)` with explanatory comments |
| `AGENTS.md` | Added two learnings: `scheduleIn(0)` footgun, socket-read blocking coroutines |

## Open Items & Next Steps

- None. Fix is minimal, all 278 existing tests pass, and the cancel flow now works correctly.

---

*Log written by write-log skill*
