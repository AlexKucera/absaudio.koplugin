-- Time-base math tests
-- Pure FFmpeg rescale (av_rescale_q) arithmetic for absaudio.koplugin (issue #32).
--
-- Run with: luajit spec/test_time_math.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local tm = require("absaudio/time_math")
local mock = require("spec/test_helper")

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
-- Slice 1: to_ms — PTS to milliseconds (tracer bullet)
-- ============================================================

run_test("to_ms: 44100 ticks of 1/44100 → 1000 ms (1s of CD audio)", function()
    mock.assert_equals(tm.to_ms(44100, { num = 1, den = 44100 }), 1000, "1 second")
end)

run_test("to_ms: 90000 ticks of 1/90000 → 1000 ms (MPEG 90 kHz)", function()
    mock.assert_equals(tm.to_ms(90000, { num = 1, den = 90000 }), 1000, "1 second")
end)

-- ============================================================
-- Slice 2: to_ms — zero, fractional, identity
-- ============================================================

run_test("to_ms: zero PTS → 0 ms", function()
    mock.assert_equals(tm.to_ms(0, { num = 1, den = 44100 }), 0, "zero")
end)

run_test("to_ms: fractional NTSC timebase 24 ticks of 1001/24000 → 1001 ms", function()
    -- 24 ticks × (1001/24000) s/tick = 1.001 s = 1001 ms
    mock.assert_equals(tm.to_ms(24, { num = 1001, den = 24000 }), 1001, "NTSC fractional")
end)

run_test("to_ms: ms timebase identity 1500 ticks of 1/1000 → 1500 ms", function()
    mock.assert_equals(tm.to_ms(1500, { num = 1, den = 1000 }), 1500, "identity")
end)

-- ============================================================
-- Slice 3: to_seconds — PTS directly to seconds
-- ============================================================

run_test("to_seconds: 44100 ticks of 1/44100 → 1 second", function()
    mock.assert_equals(tm.to_seconds(44100, { num = 1, den = 44100 }), 1, "1 second")
end)

-- ============================================================
-- Slice 4: rescale — half-away-from-zero rounding
-- ============================================================

run_test("rescale: 1 tick of 1/2 → rounds up to 1 (0.5 → 1)", function()
    mock.assert_equals(tm.rescale(1, { num = 1, den = 2 }, { num = 1, den = 1 }), 1, "half rounds up")
end)

run_test("rescale: 1 tick of 1/3 → rounds down to 0 (0.333 → 0)", function()
    mock.assert_equals(tm.rescale(1, { num = 1, den = 3 }, { num = 1, den = 1 }), 0, "thirds round down")
end)

run_test("rescale: 2 ticks of 1/3 → rounds up to 1 (0.667 → 1)", function()
    mock.assert_equals(tm.rescale(2, { num = 1, den = 3 }, { num = 1, den = 1 }), 1, "two-thirds round up")
end)

run_test("rescale: -1 tick of 1/2 → rounds away from zero to -1", function()
    mock.assert_equals(tm.rescale(-1, { num = 1, den = 2 }, { num = 1, den = 1 }), -1, "negative half rounds away")
end)

-- ============================================================
-- Slice 5: ms_to_seconds / seconds_to_ms — round-trip
-- ============================================================

run_test("seconds_to_ms: 1.5 s → 1500 ms", function()
    mock.assert_equals(tm.seconds_to_ms(1.5), 1500, "1.5s")
end)

run_test("ms_to_seconds: 1500 ms → 1.5 s", function()
    mock.assert_equals(tm.ms_to_seconds(1500), 1.5, "1500ms")
end)

run_test("seconds_to_ms/ms_to_seconds: round-trip 1.234 s", function()
    mock.assert_equals(tm.ms_to_seconds(tm.seconds_to_ms(1.234)), 1.234, "round-trip")
end)

run_test("seconds_to_ms: rounds half up 1.5005 s → 1501 ms", function()
    -- 1.5005 * 1000 = 1500.5, + 0.5 = 1501.0, floor = 1501
    mock.assert_equals(tm.seconds_to_ms(1.5005), 1501, "half up")
end)

-- ============================================================
-- Slice 6: clamp — beyond-stream-end clamping
-- ============================================================

run_test("clamp: 2000 ms beyond 1500 ms duration → 1500", function()
    mock.assert_equals(tm.clamp(2000, 1500), 1500, "clamped to duration")
end)

run_test("clamp: 1000 ms within 1500 ms duration → 1000 (unaffected)", function()
    mock.assert_equals(tm.clamp(1000, 1500), 1000, "normal unaffected")
end)

run_test("clamp: 500 ms with nil max → 500 (unchanged)", function()
    mock.assert_equals(tm.clamp(500, nil), 500, "nil max unchanged")
end)

-- ============================================================
-- Slice 7: integration — PTS beyond stream-end clamped
-- ============================================================

run_test("integration: PTS beyond stream-end clamped to duration", function()
    -- 200000 ticks of 1/44100 ≈ 4535 ms > 3000 ms duration → clamped
    mock.assert_equals(tm.clamp(tm.to_ms(200000, { num = 1, den = 44100 }), 3000), 3000, "clamped beyond-end PTS")
end)

-- Summary
print(string.format("\n%d passed, %d failed", passed, failed))
if #errors > 0 then
    print("\nFailures:")
    for _, e in ipairs(errors) do
        print("  " .. e.name .. ": " .. tostring(e.err))
    end
    os.exit(1)
end
