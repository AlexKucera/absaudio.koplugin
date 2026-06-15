-- Output pump tests for absaudio.koplugin (issue #34, audio slice C)
--
-- The output consumer of the FFmpeg audio backend's decoupled decode/output
-- design: a scheduled ~50ms pump that drains PCM from the shared pcm_buffer to
-- an INJECTABLE sink (real ALSA on device), drives the decode producer via
-- backpressure (producer:kick()), survives underrun, and self-stops when the
-- producer is done and the buffer is drained.
--
-- Tests inject FAKE sink, FAKE producer, and FAKE schedule (the module never
-- touches real UIManager/ALSA off-device). The producer is injected via opts
-- (the module does NOT require decode_producer).
--
-- Run with: luajit spec/test_output_pump.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local mock = require("spec/test_helper")
local pcm_buffer = require("absaudio/pcm_buffer")
local output_pump = require("absaudio/output_pump")

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
-- Test fakes
-- ============================================================

-- Fake schedule: records scheduled fns instead of running them. Returns a cancel fn.
local function fake_schedule()
    local scheduled = {}
    return {
        fn = function(delay, cb)
            local handle = { delay = delay, cb = cb, cancelled = false }
            table.insert(scheduled, handle)
            return function() handle.cancelled = true end
        end,
        scheduled = scheduled,   -- inspect/step from tests
    }
end

-- Fake sink: records written chunks
local function fake_sink()
    local writes = {}
    return { write = function(data, n) table.insert(writes, { data = data, n = n }) end, writes = writes }
end

-- Fake producer: controllable done flag + kick counter
local function fake_producer(opts)
    opts = opts or {}
    local kicks = 0
    return {
        kick = function() kicks = kicks + 1; return true end,
        is_done = function() return opts.done or false end,
        _kicks = function() return kicks end,
        _set_done = function(v) opts.done = v end,
    }
end

-- ============================================================
-- Slice 1: new() → is_running()==false
-- ============================================================

run_test("new: is_running() is false on a fresh pump", function()
    local buf = pcm_buffer.new(64)
    local sched = fake_schedule()
    local pump = output_pump.new({
        buffer = buf,
        sink = fake_sink(),
        producer = fake_producer(),
        schedule = sched.fn,
    })
    mock.assert_equals(pump:is_running(), false, "fresh pump is not running")
end)

-- ============================================================
-- Slice 2: start() schedules the first tick via the injected schedule
-- ============================================================

run_test("start: schedules first tick at interval delay and sets running=true", function()
    local buf = pcm_buffer.new(64)
    local sched = fake_schedule()
    local pump = output_pump.new({
        buffer = buf,
        sink = fake_sink(),
        producer = fake_producer(),
        schedule = sched.fn,
    })
    local ok = pump:start()
    mock.assert_equals(ok, true, "start returns true")
    mock.assert_equals(#sched.scheduled, 1, "exactly one tick scheduled")
    mock.assert_equals(sched.scheduled[1].delay, 0.05, "scheduled at default interval 0.05")
    mock.assert_equals(pump:is_running(), true, "pump is running after start")
end)

-- ============================================================
-- Slice 3: tick() drains data from buffer to sink
-- ============================================================

run_test("tick: drains available bytes to sink and reschedules", function()
    local buf = pcm_buffer.new(64)
    buf:write(string.rep("x", 10))
    local sink = fake_sink()
    local sched = fake_schedule()
    local prod = fake_producer()
    local pump = output_pump.new({
        buffer = buf, sink = sink, producer = prod, schedule = sched.fn,
    })
    pump:start()               -- schedules handle #1
    pump:tick()                -- drains 10 bytes
    mock.assert_equals(#sink.writes, 1, "sink.write called once")
    mock.assert_equals(sink.writes[1].n, 10, "drained all 10 bytes")
    mock.assert_equals(buf:fill(), 0, "buffer empty after drain")
    -- tick reschedules itself (handle #2 = the reschedule from tick)
    mock.assert_equals(#sched.scheduled, 2, "tick rescheduled itself")
end)

-- ============================================================
-- Slice 4: tick() drains at most chunk_size per tick
-- ============================================================

run_test("tick: drains at most chunk_size per tick across multiple ticks", function()
    local buf = pcm_buffer.new(200)
    buf:write(string.rep("y", 100))
    local sink = fake_sink()
    local sched = fake_schedule()
    local pump = output_pump.new({
        buffer = buf, sink = sink, producer = fake_producer(),
        schedule = sched.fn, chunk_size = 30,
    })
    pump:start()
    pump:tick()  -- 30
    pump:tick()  -- 30
    pump:tick()  -- 30
    pump:tick()  -- 10
    local lengths = {}
    for _, w in ipairs(sink.writes) do lengths[#lengths + 1] = w.n end
    mock.assert_equals(#sink.writes, 4, "four drain writes")
    -- Can't assert exact table equality with mock; check each
    mock.assert_equals(lengths[1], 30, "1st tick drained 30")
    mock.assert_equals(lengths[2], 30, "2nd tick drained 30")
    mock.assert_equals(lengths[3], 30, "3rd tick drained 30")
    mock.assert_equals(lengths[4], 10, "4th tick drained remaining 10")
end)

-- ============================================================
-- Slice 5: tick() kicks the producer (backpressure)
-- ============================================================

run_test("tick: kicks producer when not done", function()
    local buf = pcm_buffer.new(64)
    buf:write(string.rep("z", 10))
    local prod = fake_producer()
    local pump = output_pump.new({
        buffer = buf, sink = fake_sink(), producer = prod,
        schedule = fake_schedule().fn,
    })
    pump:start()
    pump:tick()
    mock.assert_equals(prod:_kicks() >= 1, true, "producer was kicked at least once")
end)

-- ============================================================
-- Slice 6: tick() does NOT kick when producer is done
-- ============================================================

run_test("tick: does not kick producer when done", function()
    local buf = pcm_buffer.new(64)
    buf:write(string.rep("w", 10))
    local prod = fake_producer({ done = true })
    local pump = output_pump.new({
        buffer = buf, sink = fake_sink(), producer = prod,
        schedule = fake_schedule().fn,
    })
    pump:start()
    pump:tick()
    mock.assert_equals(prod:_kicks(), 0, "producer NOT kicked when done")
end)

-- ============================================================
-- Slice 7: tick() survives underrun (empty buffer, producer not done)
-- ============================================================

run_test("tick: survives underrun — no sink write, no crash, reschedules", function()
    local buf = pcm_buffer.new(64)   -- empty
    local sink = fake_sink()
    local sched = fake_schedule()
    local pump = output_pump.new({
        buffer = buf, sink = sink, producer = fake_producer(),
        schedule = sched.fn,
    })
    pump:start()               -- handle #1
    pump:tick()                -- underrun: nothing to drain
    mock.assert_equals(#sink.writes, 0, "no sink write on empty buffer")
    mock.assert_equals(pump:is_running(), true, "still running")
    mock.assert_equals(#sched.scheduled, 2, "tick rescheduled despite underrun")
end)

-- ============================================================
-- Slice 8: natural end — producer done + buffer empty → on_drained + stop
-- ============================================================

run_test("natural end: producer done + empty buffer → on_drained fires, stops, no reschedule", function()
    local buf = pcm_buffer.new(64)   -- empty
    local drained = false
    local sink = fake_sink()
    local sched = fake_schedule()
    local pump = output_pump.new({
        buffer = buf, sink = sink, producer = fake_producer({ done = true }),
        schedule = sched.fn,
        on_drained = function() drained = true end,
    })
    pump:start()               -- handle #1
    local handles_before = #sched.scheduled
    pump:tick()
    mock.assert_equals(drained, true, "on_drained fired")
    mock.assert_equals(pump:is_running(), false, "pump stopped")
    mock.assert_equals(#sched.scheduled, handles_before, "no new handle scheduled (no reschedule)")
end)

-- ============================================================
-- Slice 9: stop() cancels the pending handle; idempotent
-- ============================================================

run_test("stop: cancels pending scheduled handle and is idempotent", function()
    local buf = pcm_buffer.new(64)
    local sched = fake_schedule()
    local pump = output_pump.new({
        buffer = buf, sink = fake_sink(), producer = fake_producer(),
        schedule = sched.fn,
    })
    pump:start()
    local handle = sched.scheduled[1]
    pump:stop()
    mock.assert_equals(handle.cancelled, true, "scheduled handle was cancelled")
    mock.assert_equals(pump:is_running(), false, "not running after stop")
    -- idempotent: calling stop again must not error
    local ok = pcall(function() pump:stop() end)
    mock.assert_equals(ok, true, "second stop() does not error")
end)

-- ============================================================
-- Slice 10: start() is idempotent
-- ============================================================

run_test("start: second start returns false and does not schedule again", function()
    local buf = pcm_buffer.new(64)
    local sched = fake_schedule()
    local pump = output_pump.new({
        buffer = buf, sink = fake_sink(), producer = fake_producer(),
        schedule = sched.fn,
    })
    local first = pump:start()
    mock.assert_equals(first, true, "first start returns true")
    local second = pump:start()
    mock.assert_equals(second, false, "second start returns false")
    mock.assert_equals(#sched.scheduled, 1, "only one handle scheduled total")
end)

-- ============================================================
-- Slice 11: full drain cycle (integration)
-- ============================================================

run_test("full drain cycle: drain-kick-reschedule, then done+drained+on_drained", function()
    local buf = pcm_buffer.new(64)
    buf:write(string.rep("a", 12))
    local sink = fake_sink()
    local prod = fake_producer({ done = false })
    local drained = false
    local sched = fake_schedule()
    local pump = output_pump.new({
        buffer = buf, sink = sink, producer = prod,
        schedule = sched.fn, chunk_size = 5,
        on_drained = function() drained = true end,
    })
    pump:start()
    -- tick 1: drain 5, kick, reschedule
    pump:tick()
    -- tick 2: drain 5, kick, reschedule
    pump:tick()
    -- now 2 bytes left; producer finishes
    prod:_set_done(true)
    -- tick 3: drain 2, no kick (done), done + empty → on_drained, stop
    pump:tick()

    local lengths = {}
    for _, w in ipairs(sink.writes) do lengths[#lengths + 1] = w.n end
    mock.assert_equals(#sink.writes, 3, "three drain writes")
    mock.assert_equals(lengths[1], 5, "1st drain 5")
    mock.assert_equals(lengths[2], 5, "2nd drain 5")
    mock.assert_equals(lengths[3], 2, "3rd drain 2")
    mock.assert_equals(drained, true, "on_drained fired")
    mock.assert_equals(pump:is_running(), false, "pump self-stopped")
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
