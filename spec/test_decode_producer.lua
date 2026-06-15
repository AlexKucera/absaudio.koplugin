-- Decode producer tests (issue #34, audio slice C)
--
-- Tests the coroutine-based decode producer's control flow with an injected
-- FAKE decoder_factory. Covers: new/start/kick lifecycle, backpressure yield,
-- frame-quota yield, EOF/finished, decode/open errors, oversized-frame guard,
-- and teardown idempotency.
--
-- Run with: luajit spec/test_decode_producer.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local mock = require("spec/test_helper")
local pcm_buffer = require("absaudio/pcm_buffer")
local decode_producer = require("absaudio/decode_producer")

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
-- Fake decoder builder for tests
-- frames: array of {pcm=<string>, pts_ms=<number>}
-- opts: { open_error=<string>, error_at=<index> }
-- ============================================================
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
                if i > #frames then return nil end  -- EOF
                return frames[i]
            end,
            close = function() closed = true end,
        }
    end
end

-- ============================================================
-- Slice 1: new — initial state
-- ============================================================

run_test("new(): status is not_started, is_done is false", function()
    local factory = fake_decoder_factory({})
    local buf = pcm_buffer.new(64)
    local p = decode_producer.new({
        decoder_factory = factory, path = "/t", buffer = buf,
    })
    mock.assert_equals(p:status(), "not_started", "initial status")
    mock.assert_equals(p:is_done(), false, "not done initially")
end)

-- ============================================================
-- Slice 2: start() with factory that errors on open
-- ============================================================

run_test("start() with open error fires on_error and marks errored", function()
    local errors_fired = {}
    local factory = fake_decoder_factory({}, { open_error = "nope" })
    local buf = pcm_buffer.new(256)
    local p = decode_producer.new({
        decoder_factory = factory, path = "/t", buffer = buf,
        on_error = function(err) table.insert(errors_fired, err) end,
    })
    p:start()
    mock.assert_equals(#errors_fired, 1, "on_error fired once")
    mock.assert_equals(errors_fired[1], "nope", "error message is the open error")
    mock.assert_equals(p:status(), "errored", "status is errored")
    mock.assert_equals(p:is_done(), true, "marked done")
end)

-- ============================================================
-- Slice 3: start() with one frame then EOF
-- ============================================================

run_test("start() with one frame then EOF: on_position, buffer fill, on_finished", function()
    local positions = {}
    local finished = false
    local factory = fake_decoder_factory({ { pcm = "ABCD", pts_ms = 1000 } })
    local buf = pcm_buffer.new(256)
    local p = decode_producer.new({
        decoder_factory = factory, path = "/t", buffer = buf,
        on_position = function(ms) table.insert(positions, ms) end,
        on_finished = function() finished = true end,
    })
    p:start()
    mock.assert_equals(positions[1], 1000, "on_position fired with 1000")
    mock.assert_equals(buf:fill(), 4, "buffer has 4 bytes")
    mock.assert_equals(finished, true, "on_finished fired")
    mock.assert_equals(p:status(), "finished", "finished")
    mock.assert_equals(p:is_done(), true, "done")
end)

-- ============================================================
-- Slice 4: on_position fires with advancing pts_ms
-- ============================================================

run_test("on_position fires per frame with advancing pts_ms", function()
    local positions = {}
    local factory = fake_decoder_factory({
        { pcm = "AAAA", pts_ms = 1000 },
        { pcm = "BBBB", pts_ms = 2000 },
        { pcm = "CCCC", pts_ms = 3000 },
    })
    local buf = pcm_buffer.new(256)
    local p = decode_producer.new({
        decoder_factory = factory, path = "/t", buffer = buf,
        on_position = function(ms) table.insert(positions, ms) end,
    })
    p:start()
    mock.assert_equals(positions[1], 1000, "first position")
    mock.assert_equals(positions[2], 2000, "second position")
    mock.assert_equals(positions[3], 3000, "third position")
end)

-- ============================================================
-- Slice 5: backpressure yield (buffer_full)
-- ============================================================

run_test("backpressure: producer yields on buffer_full, resumes after drain", function()
    local frames = {}
    for i = 1, 20 do
        frames[i] = { pcm = "ABCD", pts_ms = i * 1000 }
    end
    local factory = fake_decoder_factory(frames)
    local buf = pcm_buffer.new(4)  -- holds exactly 1 frame (4 bytes)
    local p = decode_producer.new({
        decoder_factory = factory, path = "/t", buffer = buf,
        frame_quota = 1000,  -- high to isolate buffer pressure
    })
    p:start()
    -- After start: frame 1 written (4 bytes), buffer full, yielded on frame 2
    mock.assert_equals(p:status(), "running", "yielded mid-run (buffer full)")
    mock.assert_equals(buf:full(), true, "buffer is full")
    mock.assert_equals(p:is_done(), false, "not done — still has frames")

    -- Pump/producer handshake: drain, then kick refills
    buf:read(4)
    mock.assert_equals(buf:full(), false, "buffer drained")
    p:kick()
    mock.assert_equals(buf:full(), true, "buffer refilled after kick")
    mock.assert_equals(p:status(), "running", "still running")

    -- Repeat once more
    buf:read(4)
    p:kick()
    mock.assert_equals(buf:full(), true, "refilled again")

    -- Let it finish: drain all remaining frames
    while not p:is_done() do
        buf:read(4)
        p:kick()
    end
    mock.assert_equals(p:status(), "finished", "finished after draining all 20 frames")
    mock.assert_equals(p:is_done(), true, "done")
end)

-- ============================================================
-- Slice 6: frame_quota yield (timeshare, independent of buffer pressure)
-- ============================================================

run_test("frame_quota yield: producer yields after N frames even when buffer has room", function()
    local frames = {}
    for i = 1, 5 do
        frames[i] = { pcm = "ABCD", pts_ms = i * 1000 }
    end
    local factory = fake_decoder_factory(frames)
    local buf = pcm_buffer.new(256)  -- large enough; never buffer_full
    local finished = false
    local p = decode_producer.new({
        decoder_factory = factory, path = "/t", buffer = buf,
        frame_quota = 2,
        on_finished = function() finished = true end,
    })
    p:start()
    -- After start: 2 frames processed (quota yield), 8 bytes in buffer
    mock.assert_equals(buf:fill(), 8, "2 frames * 4 bytes = 8 bytes")
    mock.assert_equals(p:status(), "running", "yielded on quota, still running")

    p:kick()
    mock.assert_equals(buf:fill(), 16, "2 more frames = 16 bytes")

    p:kick()
    -- 5th frame written + EOF
    mock.assert_equals(buf:fill(), 20, "5 frames * 4 bytes = 20 bytes total")
    mock.assert_equals(finished, true, "on_finished fired")
    mock.assert_equals(p:status(), "finished", "finished")
end)

-- ============================================================
-- Slice 7: decode error mid-stream
-- ============================================================

run_test("decode error mid-stream fires on_error and preserves prior frames", function()
    local errors_fired = {}
    local factory = fake_decoder_factory(
        { { pcm = "AB", pts_ms = 1000 }, { pcm = "CD", pts_ms = 2000 } },
        { error_at = 3 }
    )
    local buf = pcm_buffer.new(256)
    local p = decode_producer.new({
        decoder_factory = factory, path = "/t", buffer = buf,
        on_error = function(err) table.insert(errors_fired, err) end,
    })
    p:start()
    mock.assert_equals(#errors_fired, 1, "on_error fired once")
    mock.assert_equals(errors_fired[1], "decode boom", "error message")
    mock.assert_equals(p:status(), "errored", "errored")
    mock.assert_equals(p:is_done(), true, "done")
    mock.assert_equals(buf:fill(), 4, "2 prior frames (2 bytes each) still in buffer")
end)

-- ============================================================
-- Slice 8: frame larger than buffer capacity
-- ============================================================

run_test("frame larger than buffer capacity fires on_error", function()
    local errors_fired = {}
    local factory = fake_decoder_factory({ { pcm = "ABCDE", pts_ms = 1000 } })  -- 5 bytes
    local buf = pcm_buffer.new(4)  -- capacity 4
    local p = decode_producer.new({
        decoder_factory = factory, path = "/t", buffer = buf,
        on_error = function(err) table.insert(errors_fired, err) end,
    })
    p:start()
    mock.assert_equals(#errors_fired, 1, "on_error fired")
    mock.assert_equals(errors_fired[1], "decoded frame larger than buffer capacity", "error message")
    mock.assert_equals(p:status(), "errored", "errored")
end)

-- ============================================================
-- Slice 9: kick() edge cases (before start, after finished)
-- ============================================================

run_test("kick() before start() and after finish() returns false (no-op)", function()
    local factory = fake_decoder_factory({ { pcm = "A", pts_ms = 1000 } })
    local buf = pcm_buffer.new(16)
    local p = decode_producer.new({
        decoder_factory = factory, path = "/t", buffer = buf,
    })
    mock.assert_equals(p:kick(), false, "kick before start is no-op")

    p:start()
    -- single frame then EOF → finished in one resume
    mock.assert_equals(p:status(), "finished", "finished after start")
    mock.assert_equals(p:kick(), false, "kick after finish is no-op")
end)

-- ============================================================
-- Slice 10: teardown — idempotent after finish; closes decoder mid-run
-- ============================================================

run_test("teardown() after finish is idempotent and is_done() stays true", function()
    local close_calls = 0
    local factory = function(path)
        local i = 0
        return {
            read_frame = function()
                i = i + 1
                if i > 1 then return nil end
                return { pcm = "ABCD", pts_ms = 1000 }
            end,
            close = function() close_calls = close_calls + 1 end,
        }
    end
    local buf = pcm_buffer.new(256)
    local p = decode_producer.new({
        decoder_factory = factory, path = "/t", buffer = buf,
    })
    p:start()
    mock.assert_equals(p:status(), "finished", "finished")
    p:teardown()
    p:teardown()  -- idempotent
    mock.assert_equals(close_calls, 1, "close called once (during finish, not re-called by teardown)")
    mock.assert_equals(p:is_done(), true, "still done")
end)

run_test("teardown() mid-run closes the open decoder and marks done", function()
    local close_calls = 0
    local factory = function(path)
        local i = 0
        local closed = false
        return {
            read_frame = function()
                if closed then return nil end
                i = i + 1
                if i > 3 then return nil end  -- plenty of frames to stay running
                return { pcm = "AB", pts_ms = i * 1000 }
            end,
            close = function() closed = true; close_calls = close_calls + 1 end,
        }
    end
    local buf = pcm_buffer.new(2)  -- small buffer to force buffer_full yield
    local p = decode_producer.new({
        decoder_factory = factory, path = "/t", buffer = buf,
        frame_quota = 1000,
    })
    p:start()
    -- producer yielded on buffer_full after frame 1; decoder still open
    mock.assert_equals(p:status(), "running", "yielded mid-run")
    mock.assert_equals(p:is_done(), false, "not done yet")
    p:teardown()
    mock.assert_equals(close_calls, 1, "decoder close() was called on teardown")
    mock.assert_equals(p:is_done(), true, "marked done after teardown")
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
