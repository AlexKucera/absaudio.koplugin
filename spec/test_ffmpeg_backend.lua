-- FFmpeg backend skeleton tests (issue #33, audio slice B)
--
-- The FFmpeg backend implements the SAME contract as stub_backend / inkview_backend,
-- with the FFI decode layer mocked out so it is fully unit-testable on the dev Mac.
--
-- Covers acceptance criteria from issue #33:
--   * full backend contract (play/pause/resume/stop/close, get/setPosition/Duration,
--     getCurrentTrack, get/setPlaybackSpeed, isFinished, getState) + is_available()
--   * same transport state-transition behaviour as the stub/inkview backends
--   * position math + ring-buffer behaviour delegate to slice A's pure library
--   * is_available() is mockable + used by the player factory for backend selection
--   * guarded FFI lookups never crash on undefined symbols
--
-- Run with: luajit spec/test_ffmpeg_backend.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

-- Stub KOReader dependencies (mirrors test_player.lua harness)
package.loaded["ffi/blitbuffer"] = {}
package.loaded["ui/bidi"] = {}
package.loaded["device"] = {
    screen = {
        getSize = function() return { w = 600, h = 800 } end,
        scaleBySize = function(n) return n end,
    },
    hasKeys = function() return false end,
    isTouchDevice = function() return false end,
    input = { group = { Back = { "Back" } } },
}
package.loaded["ui/time"] = nil  -- let the backend use its own wall-clock resolver
package.loaded["abs_logger"] = {
    verbose = function() end,
    info = function() end,
    warn = function() end,
}

local mock = require("spec/test_helper")
local ffmpeg_backend = require("absaudio/ffmpeg_backend")

local passed = 0
local failed = 0
local errors = {}

local function run_test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("  ✓ " .. name)
    else
        failed = failed + 1
        table.insert(errors, { name = name, err = err })
        print("  ✗ " .. name)
        print("    " .. tostring(err))
    end
end

-- ============================================================
-- Slice 0: new() + getState/getDuration
-- ============================================================

run_test("new(): returns instance in stopped state with summed duration", function()
    local b = ffmpeg_backend.new({
        track_durations = { 300, 240, 280 },
        file_paths = { "/t1.m4b", "/t2.m4b", "/t3.m4b" },
    })
    mock.assert_equals(b:getState(), "stopped", "initial state is stopped")
    mock.assert_equals(b:getDuration(), 820, "total duration is sum of tracks")
    b:close()
end)

-- ============================================================
-- Slice 1: is_available() default probe (guarded FFI; false on dev Mac)
-- ============================================================

run_test("is_available(): returns false on the dev Mac (no libaudio-engine.so)", function()
    ffmpeg_backend._set_probe_override(nil)  -- restore default probe
    mock.assert_equals(ffmpeg_backend.is_available(), false,
        "guarded FFI probe returns false when the toolkit lib is absent")
end)

run_test("is_available(): never crashes even if FFI is present but lib missing", function()
    ffmpeg_backend._set_probe_override(nil)
    -- Must not throw; a missing symbol/library is a normal 'false', not a crash
    local ok, result = pcall(function() return ffmpeg_backend.is_available() end)
    mock.assert_equals(ok, true, "probe does not throw")
    mock.assert_equals(result, false, "returns false on dev")
end)

-- ============================================================
-- Slice 2: is_available() is mockable (module override + opts.ffi_probe)
-- ============================================================

run_test("is_available(): module-level override forces true (device simulation)", function()
    ffmpeg_backend._set_probe_override(function() return true end)
    mock.assert_equals(ffmpeg_backend.is_available(), true, "override forces available")
    ffmpeg_backend._set_probe_override(nil)  -- restore
    mock.assert_equals(ffmpeg_backend.is_available(), false, "restored default → false")
end)

run_test("is_available(): opts.ffi_probe overrides per-instance without touching module", function()
    ffmpeg_backend._set_probe_override(nil)  -- module says false
    local b_dev = ffmpeg_backend.new({ track_durations = { 100 } })
    local b_device = ffmpeg_backend.new({
        track_durations = { 100 },
        ffi_probe = function() return true end,
    })
    mock.assert_equals(b_dev:is_available(), false, "instance with no probe follows module")
    mock.assert_equals(b_device:is_available(), true, "instance probe overrides")
    mock.assert_equals(ffmpeg_backend.is_available(), false, "module-level unaffected")
    b_dev:close()
    b_device:close()
end)

-- ============================================================
-- Slice 3: transport lifecycle (play/pause/resume/stop)
-- ============================================================

run_test("play(): transitions stopped → playing", function()
    local b = ffmpeg_backend.new({ track_durations = { 300 } })
    b:play()
    mock.assert_equals(b:getState(), "playing", "now playing")
    b:close()
end)

run_test("pause(): transitions playing → paused", function()
    local b = ffmpeg_backend.new({ track_durations = { 300 } })
    b:play()
    b:pause()
    mock.assert_equals(b:getState(), "paused", "now paused")
    b:close()
end)

run_test("resume(): transitions paused → playing", function()
    local b = ffmpeg_backend.new({ track_durations = { 300 } })
    b:play()
    b:pause()
    b:resume()
    mock.assert_equals(b:getState(), "playing", "resumed playing")
    b:close()
end)

run_test("stop(): transitions playing/paused → stopped", function()
    local b = ffmpeg_backend.new({ track_durations = { 300 } })
    b:play()
    b:stop()
    mock.assert_equals(b:getState(), "stopped", "stopped from playing")
    b:play()
    b:pause()
    b:stop()
    mock.assert_equals(b:getState(), "stopped", "stopped from paused")
    b:close()
end)

-- ============================================================
-- Slice 4: idempotent transitions (no-op when preconditions unmet)
-- ============================================================

run_test("play() when already playing is no-op", function()
    local b = ffmpeg_backend.new({ track_durations = { 300 } })
    b:play()
    b:play()  -- second play must not error or reset state
    mock.assert_equals(b:getState(), "playing", "still playing")
    b:close()
end)

run_test("pause() when stopped is no-op", function()
    local b = ffmpeg_backend.new({ track_durations = { 300 } })
    b:pause()
    mock.assert_equals(b:getState(), "stopped", "still stopped")
    b:close()
end)

run_test("resume() when not paused is no-op", function()
    local b = ffmpeg_backend.new({ track_durations = { 300 } })
    b:resume()  -- not paused
    mock.assert_equals(b:getState(), "stopped", "still stopped when resuming from stopped")
    b:play()
    b:resume()  -- already playing
    mock.assert_equals(b:getState(), "playing", "still playing when resuming while playing")
    b:close()
end)

-- ============================================================
-- Slice 5: position advances over time (time_math conversion + speed)
-- ============================================================

run_test("play + _advanceTime advances position at 1x", function()
    local b = ffmpeg_backend.new({ track_durations = { 100 } })
    b:play()
    b:_advanceTime(5)
    mock.assert_equals(b:getPosition(), 5, "position advanced 5s")
    b:close()
end)

run_test("playback speed scales position advance", function()
    local b = ffmpeg_backend.new({ track_durations = { 100 }, playback_speed = 2.0 })
    b:play()
    b:_advanceTime(5)  -- 5 real seconds at 2x = 10s of audio
    mock.assert_equals(b:getPosition(), 10, "2x speed: 5s * 2 = 10s position")
    b:close()
end)

run_test("getPosition returns start_position before play", function()
    local b = ffmpeg_backend.new({ track_durations = { 300 }, start_position = 50 })
    mock.assert_equals(b:getPosition(), 50, "position is 50 before play")
    b:close()
end)

-- ============================================================
-- Slice 6: pause freezes position; resume continues from pause point
-- ============================================================

run_test("pause freezes position (no advance while paused)", function()
    local b = ffmpeg_backend.new({ track_durations = { 200 } })
    b:play()
    b:_advanceTime(10)
    b:pause()
    local pos_at_pause = b:getPosition()
    b:_advanceTime(5)  -- time passes while paused — must not count
    mock.assert_equals(b:getPosition(), pos_at_pause, "position frozen during pause")
    b:close()
end)

run_test("resume continues from paused position", function()
    local b = ffmpeg_backend.new({ track_durations = { 200 } })
    b:play()
    b:_advanceTime(10)
    b:pause()
    b:_advanceTime(5)  -- paused time (ignored)
    b:resume()
    b:_advanceTime(3)  -- 3s more of playback
    mock.assert_equals(b:getPosition(), 13, "10 + 0 + 3 = 13")
    b:close()
end)

-- ============================================================
-- Slice 7: getPosition clamps to duration via time_math.clamp
-- ============================================================

run_test("getPosition never exceeds duration (clamped)", function()
    local b = ffmpeg_backend.new({ track_durations = { 30 } })
    b:play()
    b:_advanceTime(1000)  -- way past the 30s duration
    mock.assert_equals(b:getPosition(), 30, "position clamped to duration")
    b:close()
end)

-- ============================================================
-- Slice 8: setPosition seeks + clamps, re-baselines while playing
-- ============================================================

run_test("setPosition seeks within range", function()
    local b = ffmpeg_backend.new({ track_durations = { 300, 240 } })
    b:play()
    b:setPosition(150)
    mock.assert_equals(b:getPosition(), 150, "position updated")
    b:close()
end)

run_test("setPosition clamps negative → 0", function()
    local b = ffmpeg_backend.new({ track_durations = { 100 } })
    b:play()
    b:setPosition(-10)
    mock.assert_equals(b:getPosition(), 0, "negative clamped to 0")
    b:close()
end)

run_test("setPosition clamps over duration → duration", function()
    local b = ffmpeg_backend.new({ track_durations = { 100 } })
    b:play()
    b:setPosition(9999)
    mock.assert_equals(b:getPosition(), 100, "over-duration clamped to duration")
    b:close()
end)

run_test("setPosition while playing re-baselines clock (no jump after seek)", function()
    local b = ffmpeg_backend.new({ track_durations = { 200 } })
    b:play()
    b:_advanceTime(20)
    b:setPosition(80)
    b:_advanceTime(5)
    mock.assert_equals(b:getPosition(), 85, "resumed from 80, advanced 5s")
    b:close()
end)

run_test("setPosition while paused holds the seek point", function()
    local b = ffmpeg_backend.new({ track_durations = { 200 } })
    b:play()
    b:_advanceTime(20)
    b:pause()
    b:setPosition(80)
    b:_advanceTime(5)  -- paused, ignored
    mock.assert_equals(b:getPosition(), 80, "paused seek holds at 80")
    b:close()
end)

-- ============================================================
-- Slice 9: auto-finish + on_finished callback
-- ============================================================

run_test("auto-finish at end of duration: state stopped, isFinished true", function()
    local b = ffmpeg_backend.new({ track_durations = { 10 } })
    b:play()
    b:_advanceTime(10)  -- reaches end
    mock.assert_equals(b:getState(), "stopped", "auto-stopped at end")
    mock.assert_equals(b:isFinished(), true, "marked finished")
    b:close()
end)

run_test("auto-finish fires on_finished with final position", function()
    local fired, final_pos = false, nil
    local b = ffmpeg_backend.new({
        track_durations = { 5, 5 },
        on_finished = function(pos) fired = true final_pos = pos end,
    })
    b:play()
    b:_advanceTime(10)
    mock.assert_equals(fired, true, "callback fired")
    mock.assert_equals(final_pos, 10, "callback received final position")
    b:close()
end)

run_test("manual stop does NOT fire on_finished and does not mark finished", function()
    local fired = false
    local b = ffmpeg_backend.new({
        track_durations = { 100 },
        on_finished = function() fired = true end,
    })
    b:play()
    b:_advanceTime(10)
    b:stop()
    mock.assert_equals(fired, false, "callback NOT fired on manual stop")
    mock.assert_equals(b:isFinished(), false, "not marked finished on manual stop")
    b:close()
end)

run_test("seek past end triggers auto-finish", function()
    local b = ffmpeg_backend.new({ track_durations = { 10 } })
    b:play()
    b:setPosition(10)  -- exactly at end
    mock.assert_equals(b:getState(), "stopped", "stopped when seeking to end")
    mock.assert_equals(b:isFinished(), true, "finished when seeking to end")
    b:close()
end)

-- ============================================================
-- Slice 10: stop() resets position + current track
-- ============================================================

run_test("stop resets position to 0 and clears current track", function()
    local b = ffmpeg_backend.new({ track_durations = { 100, 200 } })
    b:play()
    b:_advanceTime(50)
    mock.assert_equals(b:getCurrentTrack(), 1, "on track 1 before stop")
    b:stop()
    mock.assert_equals(b:getPosition(), 0, "position reset to 0")
    mock.assert_equals(b:getCurrentTrack(), 0, "current track cleared")
    mock.assert_equals(b:getState(), "stopped", "stopped")
    b:close()
end)

-- ============================================================
-- Slice 11: getCurrentTrack maps position to track index
-- ============================================================

run_test("getCurrentTrack: track 1 at start, track 2 after boundary", function()
    local b = ffmpeg_backend.new({ track_durations = { 100, 200 } })
    b:play()
    mock.assert_equals(b:getCurrentTrack(), 1, "starts on track 1")
    b:_advanceTime(99)
    mock.assert_equals(b:getCurrentTrack(), 1, "still track 1 at 99s")
    b:_advanceTime(2)  -- 101s → track 2
    mock.assert_equals(b:getCurrentTrack(), 2, "moved to track 2 after boundary")
    b:close()
end)

run_test("getCurrentTrack: 0 when stopped", function()
    local b = ffmpeg_backend.new({ track_durations = { 100 } })
    mock.assert_equals(b:getCurrentTrack(), 0, "no current track when stopped")
    b:close()
end)

run_test("start_position places initial current track correctly", function()
    local b = ffmpeg_backend.new({ track_durations = { 300, 200 }, start_position = 250 })
    b:play()
    mock.assert_equals(b:getCurrentTrack(), 1, "track 1 at 250s (duration 300)")
    b:close()
end)

-- ============================================================
-- Slice 12: getPlaybackSpeed / setPlaybackSpeed
-- ============================================================

run_test("getPlaybackSpeed defaults to 1.0", function()
    local b = ffmpeg_backend.new({ track_durations = { 100 } })
    mock.assert_equals(b:getPlaybackSpeed(), 1.0, "default speed 1.0")
    b:close()
end)

run_test("setPlaybackSpeed updates and persists the value", function()
    local b = ffmpeg_backend.new({ track_durations = { 100 } })
    b:setPlaybackSpeed(1.5)
    mock.assert_equals(b:getPlaybackSpeed(), 1.5, "speed updated to 1.5")
    b:close()
end)

run_test("setPlaybackSpeed while playing re-baselines (no jump)", function()
    local b = ffmpeg_backend.new({ track_durations = { 200 }, playback_speed = 1.0 })
    b:play()
    b:_advanceTime(10)  -- 10s at 1x = 10
    b:setPlaybackSpeed(2.0)
    b:_advanceTime(5)   -- 5s at 2x = 10 more → 20
    mock.assert_equals(b:getPosition(), 20, "10 + 5*2 = 20")
    b:close()
end)

run_test("playback_speed opt scales advance from the start", function()
    local b = ffmpeg_backend.new({ track_durations = { 100 }, playback_speed = 2.0 })
    mock.assert_equals(b:getPlaybackSpeed(), 2.0, "opt playback_speed honored")
    b:close()
end)

-- ============================================================
-- Slice 13: close() resets everything (including finished)
-- ============================================================

run_test("close() resets state, position, and finished flag", function()
    local b = ffmpeg_backend.new({ track_durations = { 5 } })
    b:play()
    b:_advanceTime(5)  -- auto-finish
    mock.assert_equals(b:isFinished(), true, "finished before close")
    b:close()
    mock.assert_equals(b:getState(), "stopped", "state reset")
    mock.assert_equals(b:getPosition(), 0, "position reset")
    mock.assert_equals(b:isFinished(), false, "finished flag cleared")
    mock.assert_equals(b:getCurrentTrack(), 0, "track cleared")
end)

-- ============================================================
-- Slice 14: ring buffer delegation (slice A pure library)
-- ============================================================

run_test("getRingBuffer: owns a ring_buffer with fill=0 / free=capacity", function()
    local rb = require("absaudio/ring_buffer")
    local b = ffmpeg_backend.new({ track_durations = { 100 } })
    local ring = b:getRingBuffer()
    mock.assert_equals(ring ~= nil, true, "backend owns a ring buffer")
    mock.assert_equals(rb.fill(ring), 0, "fresh ring buffer is empty")
    mock.assert_equals(rb.free(ring), 1024 * 1024, "free == default 1 MiB capacity")
    b:close()
end)

run_test("buffer_capacity opt configures the ring buffer", function()
    local rb = require("absaudio/ring_buffer")
    local b = ffmpeg_backend.new({ track_durations = { 100 }, buffer_capacity = 4096 })
    mock.assert_equals(rb.free(b:getRingBuffer()), 4096, "custom capacity honored")
    b:close()
end)

-- ============================================================
-- Slice 15: guarded FFI — never crashes; probe is stable/memoized
-- ============================================================

run_test("is_available(): stable across repeated calls (memoized, never crashes)", function()
    ffmpeg_backend._set_probe_override(nil)
    local r1 = ffmpeg_backend.is_available()
    local r2 = ffmpeg_backend.is_available()
    local r3 = ffmpeg_backend.is_available()
    mock.assert_equals(r1, r2, "call 1 == call 2")
    mock.assert_equals(r2, r3, "call 2 == call 3 (memoized)")
    mock.assert_equals(r1, false, "false on dev")
end)

run_test("is_available(): returns false on dev even though luajit FFI is present", function()
    -- luajit ships ffi, but libaudio-engine.so does not load on the dev Mac.
    -- This proves the probe distinguishes 'ffi available' from 'backend available'.
    local has_ffi = pcall(require, "ffi")
    mock.assert_equals(has_ffi, true, "precondition: luajit ffi IS present in tests")
    ffmpeg_backend._set_probe_override(nil)
    mock.assert_equals(ffmpeg_backend.is_available(), false,
        "ffi present but toolkit lib absent → false")
end)

-- Summary

-- ============================================================
-- Slice 16-17: player factory — explicit ffmpeg + auto-detect selection
-- ============================================================

local player = require("absaudio/player")

run_test("factory: backend='ffmpeg' selects the ffmpeg backend", function()
    local p = player.create({
        track_durations = { 300, 240 },
        file_paths = { "/t1.m4b", "/t2.m4b" },
        backend = "ffmpeg",
    })
    mock.assert_equals(p:getBackendName(), "ffmpeg", "ffmpeg explicitly selected")
    mock.assert_equals(p:getState(), "stopped", "initial state")
    mock.assert_equals(p:getDuration(), 540, "duration")
    p:play()
    mock.assert_equals(p:getState(), "playing", "transport works via ffmpeg")
    p:close()
end)

run_test("factory: auto-detect picks stub when ffmpeg unavailable (dev)", function()
    ffmpeg_backend._set_probe_override(nil)  -- dev: libaudio-engine absent → false
    local p = player.create({
        track_durations = { 100 },
        file_paths = { "/t.m4b" },
        backend = "auto",
    })
    mock.assert_equals(p:getBackendName(), "stub", "falls back to stub on dev")
    p:close()
end)

run_test("factory: omitted backend auto-detects (stub on dev)", function()
    ffmpeg_backend._set_probe_override(nil)
    local p = player.create({ track_durations = { 100 }, file_paths = { "/t.m4b" } })
    mock.assert_equals(p:getBackendName(), "stub", "omitted backend → stub on dev")
    p:close()
end)

run_test("factory: auto-detect picks ffmpeg when is_available() is true (device)", function()
    ffmpeg_backend._set_probe_override(function() return true end)  -- simulate device
    local p = player.create({
        track_durations = { 100 },
        file_paths = { "/t.m4b" },
        backend = "auto",
    })
    mock.assert_equals(p:getBackendName(), "ffmpeg", "ffmpeg selected when available")
    -- transport still works end-to-end through the selected backend
    p:play()
    p:_advanceTime(5)
    mock.assert_equals(p:getPosition(), 5, "position advances via auto-selected backend")
    p:close()
    ffmpeg_backend._set_probe_override(nil)  -- restore for any later tests
end)

run_test("factory: explicit 'stub' is never overridden by auto-detect", function()
    ffmpeg_backend._set_probe_override(function() return true end)  -- even if device
    local p = player.create({
        track_durations = { 100 },
        file_paths = { "/t.m4b" },
        backend = "stub",
    })
    mock.assert_equals(p:getBackendName(), "stub", "explicit stub respected")
    p:close()
    ffmpeg_backend._set_probe_override(nil)
end)
print(string.format("\n%d passed, %d failed", passed, failed))
if #errors > 0 then
    print("\nFailures:")
    for _, e in ipairs(errors) do
        print("  " .. e.name .. ": " .. e.err)
    end
    os.exit(1)
end
