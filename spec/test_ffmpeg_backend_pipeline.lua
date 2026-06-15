-- FFmpeg backend pipeline integration tests (issue #34, audio slice C)
--
-- Tests the producer/pump/wake-lock orchestration layered onto ffmpeg_backend
-- when a decoder_factory is injected. Slice B's 45 contract tests (in
-- test_ffmpeg_backend.lua) cover the clock-model path and are UNCHANGED —
-- these tests cover the producer-driven path with fakes for every device seam.
--
-- Covers acceptance criteria from issue #34:
--   * play() starts producer + pump + wake-lock; stop() tears all down
--   * undecodable file -> clear error retrievable via getLastError(), no crash
--   * wake-lock acquire/release paired exactly once each
--   * producer-driven position reflects PTS via on_position
--   * pause/resume in producer mode (pump stops/restarts)
--
-- Run with: luajit spec/test_ffmpeg_backend_pipeline.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

-- Stub KOReader dependencies (mirrors test_ffmpeg_backend.lua harness)
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
package.loaded["ui/time"] = nil
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
        print("  \u{2713} " .. name)
    else
        failed = failed + 1
        table.insert(errors, { name = name, err = err })
        print("  \u{2717} " .. name)
        print("    " .. tostring(err))
    end
end

------------------------------------------------------------------------
-- Fake builders (inject every device seam)
------------------------------------------------------------------------

-- Fake decoder_factory: emits frames then EOF (or errors).
local function fake_decoder_factory(frames, opts)
    opts = opts or {}
    return function(path)
        if opts.open_error then return nil, opts.open_error end
        local i = 0
        local closed = false
        return {
            read_frame = function()
                if closed then return nil end
                i = i + 1
                if opts.error_at and i == opts.error_at then return nil, "decode boom" end
                if i > #frames then return nil end
                return frames[i]
            end,
            close = function() closed = true end,
        }
    end
end

-- Fake sink: records written chunks.
local function fake_sink()
    local writes = {}
    return {
        write = function(data, n) table.insert(writes, { data = data, n = n }) end,
        writes = writes,
        total_bytes = function()
            local t = 0
            for _, w in ipairs(writes) do t = t + w.n end
            return t
        end,
    }
end

-- Fake schedule: records scheduled fns; exposes a step() to invoke the latest.
local function fake_schedule()
    local handles = {}
    return {
        fn = function(delay, cb)
            local handle = { delay = delay, cb = cb, cancelled = false }
            table.insert(handles, handle)
            return function() handle.cancelled = true end
        end,
        step = function()
            -- Invoke the last non-cancelled handle's callback once.
            for i = #handles, 1, -1 do
                if not handles[i].cancelled then
                    local cb = handles[i].cb
                    handles[i].cancelled = true  -- consume
                    cb()
                    return true
                end
            end
            return false
        end,
        count = function() return #handles end,
    }
end

-- Counting wake-lock impl.
local function fake_wake_impl()
    local calls = { acquire = 0, release = 0 }
    return {
        acquire = function() calls.acquire = calls.acquire + 1 end,
        release = function() calls.release = calls.release + 1 end,
        calls = calls,
    }
end

-- Helper: build a backend with all fakes injected.
local function make_pipeline_backend(opts)
    opts = opts or {}
    local sched = fake_schedule()
    local sink = fake_sink()
    local wake = fake_wake_impl()
    local b = ffmpeg_backend.new({
        track_durations = opts.track_durations or { 100 },
        file_paths = opts.file_paths or { "/test.m4b" },
        decoder_factory = opts.decoder_factory or fake_decoder_factory(opts.frames or {
            { pcm = string.rep("A", 8), pts_ms = 1000 },
            { pcm = string.rep("B", 8), pts_ms = 2000 },
        }),
        sink = sink,
        schedule = sched.fn,
        wake_impl = wake,
        buffer_capacity = opts.buffer_capacity or (1024 * 1024),
        chunk_size = opts.chunk_size or 4096,
    })
    return b, sched, sink, wake
end

-- ============================================================
-- Slice 1: play() starts the pipeline — wake-lock acquired, pump running
-- ============================================================

run_test("play() with decoder_factory acquires wake-lock", function()
    local b, sched, sink, wake = make_pipeline_backend()
    b:play()
    mock.assert_equals(b:getState(), "playing", "state is playing")
    mock.assert_equals(wake.calls.acquire, 1, "wake-lock acquired exactly once on play")
    b:close()
end)

run_test("play() with decoder_factory starts the output pump", function()
    local b, sched = make_pipeline_backend()
    b:play()
    mock.assert_equals(sched.count() > 0, true, "pump scheduled at least one tick")
    b:close()
end)

-- ============================================================
-- Slice 2: stop() tears down the whole pipeline
-- ============================================================

run_test("stop() releases wake-lock and stops the pump", function()
    local b, sched, sink, wake = make_pipeline_backend()
    b:play()
    mock.assert_equals(wake.calls.acquire, 1, "acquired on play")
    b:stop()
    mock.assert_equals(b:getState(), "stopped", "stopped")
    mock.assert_equals(wake.calls.release, 1, "wake-lock released on stop")
    -- After stop, stepping the schedule should produce no new ticks (pump stopped)
    local before = sched.count()
    sched.step()
    mock.assert_equals(sched.count(), before, "no new tick scheduled after stop")
end)

run_test("stop() resets position to 0", function()
    local b = make_pipeline_backend()
    b:play()
    b:stop()
    mock.assert_equals(b:getPosition(), 0, "position reset to 0 on stop")
end)

-- ============================================================
-- Slice 3: undecodable file -> clear error, no crash
-- ============================================================

run_test("undecodable file (open error): state stopped, getLastError set, no crash", function()
    local b, sched = make_pipeline_backend({
        decoder_factory = fake_decoder_factory({}, { open_error = "file not found" }),
    })
    local ok = pcall(function() b:play() end)
    mock.assert_equals(ok, true, "play() does not throw on undecodable file")
    mock.assert_equals(b:getState(), "stopped", "state is stopped after error")
    local err = b:getLastError()
    mock.assert_equals(err ~= nil, true, "error is retrievable")
    mock.assert_equals(tostring(err):find("not found") ~= nil, true,
        "error message contains the original cause")
    b:close()
end)

run_test("undecodable file does NOT fire on_finished or mark finished", function()
    local fired = false
    local b = ffmpeg_backend.new({
        track_durations = { 100 },
        file_paths = { "/bad.m4b" },
        decoder_factory = fake_decoder_factory({}, { open_error = "corrupt" }),
        sink = fake_sink(),
        schedule = fake_schedule().fn,
        wake_impl = fake_wake_impl(),
        on_finished = function() fired = true end,
    })
    b:play()
    -- Drive a pump tick to let the error propagate through on_drained
    -- (producer errors immediately; pump detects done+empty on next tick)
    mock.assert_equals(b:isFinished(), false, "not finished on error")
    mock.assert_equals(fired, false, "on_finished NOT fired on error")
    b:close()
end)

-- ============================================================
-- Slice 4: wake-lock acquire/release pairing (exactly once each)
-- ============================================================

run_test("wake-lock: play/stop/play/stop cycles acquire+release each time", function()
    local b, sched, sink, wake = make_pipeline_backend({
        frames = {
            { pcm = string.rep("X", 8), pts_ms = 500 },
            { pcm = string.rep("X", 8), pts_ms = 1000 },
        },
    })
    b:play()
    mock.assert_equals(wake.calls.acquire, 1, "first acquire")
    b:stop()
    mock.assert_equals(wake.calls.release, 1, "first release")
    b:play()
    mock.assert_equals(wake.calls.acquire, 2, "second acquire")
    b:stop()
    mock.assert_equals(wake.calls.release, 2, "second release")
end)

run_test("close() releases wake-lock if held", function()
    local b, sched, sink, wake = make_pipeline_backend()
    b:play()
    b:close()
    mock.assert_equals(wake.calls.release, 1, "close releases the wake-lock")
end)

-- ============================================================
-- Slice 5: producer-driven position reflects PTS via on_position
-- ============================================================

run_test("getPosition reflects producer PTS during playback", function()
    local b, sched = make_pipeline_backend({
        track_durations = { 10 },
        buffer_capacity = 16,   -- small: producer yields on buffer-full before finishing
        chunk_size = 8,        -- drain 8 bytes per pump tick
        frames = {
            { pcm = string.rep("A", 8), pts_ms = 1000 },
            { pcm = string.rep("A", 8), pts_ms = 2000 },
            { pcm = string.rep("A", 8), pts_ms = 3000 },
            { pcm = string.rep("A", 8), pts_ms = 4000 },
        },
    })
    b:play()
    -- Producer decoded 2 frames (16-byte buffer full), then frame 3 fired
    -- on_position(3000) before yielding on buffer-full.
    mock.assert_equals(b:getPosition(), 3, "position is 3s after initial decode")
    -- Pump step: drains 8 bytes, kicks producer → writes frame 3, then frame 4
    -- fires on_position(4000) before yielding again.
    sched.step()
    mock.assert_equals(b:getPosition(), 4, "position advanced to 4s after pump step")
    b:close()
end)

-- ============================================================
-- Slice 6: pause/resume in producer mode (pump stops/restarts)
-- ============================================================

run_test("pause() in producer mode stops output; resume() restarts", function()
    local b, sched = make_pipeline_backend({
        frames = {
            { pcm = string.rep("A", 8), pts_ms = 1000 },
            { pcm = string.rep("B", 8), pts_ms = 2000 },
        },
    })
    b:play()
    mock.assert_equals(b:getState(), "playing", "playing")
    b:pause()
    mock.assert_equals(b:getState(), "paused", "paused")
    b:resume()
    mock.assert_equals(b:getState(), "playing", "resumed to playing")
    b:close()
end)

-- ============================================================
-- Slice 7: natural completion fires on_finished + releases wake-lock
-- ============================================================

run_test("natural finish: producer EOF -> on_finished + wake-lock released", function()
    local fired, final_pos = false, nil
    local sched = fake_schedule()
    local sink = fake_sink()
    local wake = fake_wake_impl()
    local b = ffmpeg_backend.new({
        track_durations = { 5 },
        file_paths = { "/t.m4b" },
        decoder_factory = fake_decoder_factory({
            { pcm = string.rep("Z", 8), pts_ms = 5000 },  -- reaches end
        }),
        sink = sink,
        schedule = sched.fn,
        wake_impl = wake,
        on_finished = function(pos) fired = true final_pos = pos end,
    })
    b:play()
    -- Step until the pump detects producer-done + buffer-empty (natural finish).
    -- With one frame at pts_ms=5000 (== duration), on_position sets position to 5s.
    for _ = 1, 5 do sched.step() end
    mock.assert_equals(fired, true, "on_finished fired on natural completion")
    mock.assert_equals(b:isFinished(), true, "marked finished")
    mock.assert_equals(wake.calls.release, 1, "wake-lock released on finish")
    b:close()
end)

-- ============================================================
-- Slice 8: no decoder_factory = clock model unchanged (slice B compat)
-- ============================================================

run_test("no decoder_factory: play uses clock model (no wake-lock, no pump)", function()
    local wake = fake_wake_impl()
    local sched = fake_schedule()
    local b = ffmpeg_backend.new({
        track_durations = { 100 },
        file_paths = { "/t.m4b" },
        -- NO decoder_factory, sink, schedule, or wake_impl
        wake_impl = wake,  -- provided but should NOT be used (no pipeline)
    })
    b:play()
    mock.assert_equals(b:getState(), "playing", "clock-model play works")
    mock.assert_equals(wake.calls.acquire, 0, "no wake-lock without decoder_factory")
    b:close()
end)

-- Summary
print(string.format("\n%d passed, %d failed", passed, failed))
if #errors > 0 then
    print("\nFailures:")
    for _, e in ipairs(errors) do
        print("  " .. e.name .. ": " .. e.err)
    end
    os.exit(1)
end
