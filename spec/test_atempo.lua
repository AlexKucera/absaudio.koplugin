-- Atempo filter-chain builder tests
-- Pure-logic FFmpeg atempo filter-chain string construction for absaudio.koplugin.
--
-- Covers acceptance criteria from issue #32 (audio slice A):
--   single-stage speeds 0.5-2.0; chaining for out-of-range multipliers;
--   the plugin's speed presets; error handling for non-positive/non-number input.
--
-- Run with: luajit spec/test_atempo.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local atempo = require("absaudio/atempo")
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

local function assert_error(name, fn)
    local ok = pcall(fn)
    mock.assert_equals(ok, false, name .. " should error")
end

-- ============================================================
-- Slice 1: chain() — single-stage mid-range (tracer bullet)
-- Scenario: at 1x speed no tempo change is needed; the builder
-- emits a single atempo stage at 1.
-- ============================================================

run_test("chain: 1.0 → single stage 'atempo=1'", function()
    mock.assert_equals(atempo.chain(1.0), "atempo=1", "1x tempo")
end)

-- ============================================================
-- Slice 2: chain() — other mid-range single-stage speeds
-- ============================================================

run_test("chain: 1.5 → 'atempo=1.5'", function()
    mock.assert_equals(atempo.chain(1.5), "atempo=1.5", "1.5x tempo")
end)

-- ============================================================
-- Slice 3: chain() — single-stage boundaries (acceptance)
-- 0.5 and 2.0 are exactly at the stage limits and still fit ONE stage.
-- ============================================================

run_test("chain: 0.5 (min single stage) → 'atempo=0.5'", function()
    mock.assert_equals(atempo.chain(0.5), "atempo=0.5", "min single stage")
end)

run_test("chain: 2.0 (max single stage) → 'atempo=2'", function()
    mock.assert_equals(atempo.chain(2.0), "atempo=2", "max single stage")
end)

-- ============================================================
-- Slice 4: chain() — plugin speed presets within single-stage range
-- All UI presets (0.5-2.0) emit exactly one stage.
-- ============================================================

run_test("chain: preset 0.75 → 'atempo=0.75'", function()
    mock.assert_equals(atempo.chain(0.75), "atempo=0.75", "0.75x preset")
end)

run_test("chain: preset 1.25 → 'atempo=1.25'", function()
    mock.assert_equals(atempo.chain(1.25), "atempo=1.25", "1.25x preset")
end)

run_test("chain: preset 1.75 → 'atempo=1.75'", function()
    mock.assert_equals(atempo.chain(1.75), "atempo=1.75", "1.75x preset")
end)

-- ============================================================
-- Slice 5: chain() UP — out-of-range speeds require chaining
-- 4x = 2.0 * 2.0 (two max stages); remainder lands in range.
-- ============================================================

run_test("chain: 4.0 → 'atempo=2,atempo=2'", function()
    mock.assert_equals(atempo.chain(4.0), "atempo=2,atempo=2", "4x = two stages")
end)

run_test("chain: 3.0 → 'atempo=2,atempo=1.5'", function()
    mock.assert_equals(atempo.chain(3.0), "atempo=2,atempo=1.5", "3x = 2 then 1.5")
end)

run_test("chain: 8.0 → 'atempo=2,atempo=2,atempo=2'", function()
    mock.assert_equals(atempo.chain(8.0), "atempo=2,atempo=2,atempo=2", "8x = three stages")
end)

run_test("chain: 5.0 → 'atempo=2,atempo=2,atempo=1.25'", function()
    mock.assert_equals(atempo.chain(5.0), "atempo=2,atempo=2,atempo=1.25", "5x = 2,2,1.25")
end)

-- ============================================================
-- Slice 6: chain() DOWN — sub-0.5 speeds require chaining
-- 0.25x = 0.5 * 0.5 (two min stages).
-- ============================================================

run_test("chain: 0.25 → 'atempo=0.5,atempo=0.5'", function()
    mock.assert_equals(atempo.chain(0.25), "atempo=0.5,atempo=0.5", "0.25x = two stages")
end)

run_test("chain: 0.3 → 'atempo=0.5,atempo=0.6'", function()
    mock.assert_equals(atempo.chain(0.3), "atempo=0.5,atempo=0.6", "0.3x = 0.5 then 0.6")
end)

run_test("chain: 0.1 → 'atempo=0.5,atempo=0.5,atempo=0.5,atempo=0.8'", function()
    mock.assert_equals(atempo.chain(0.1), "atempo=0.5,atempo=0.5,atempo=0.5,atempo=0.8", "0.1x = four stages")
end)

-- ============================================================
-- Slice 7: chain() — error handling for invalid input
-- Non-positive numbers and non-numbers must error.
-- ============================================================

run_test("chain: 0 errors", function()
    assert_error("chain(0)", function() atempo.chain(0) end)
end)

run_test("chain: -1 errors", function()
    assert_error("chain(-1)", function() atempo.chain(-1) end)
end)

run_test("chain: nil errors", function()
    assert_error("chain(nil)", function() atempo.chain(nil) end)
end)

run_test("chain: string errors", function()
    assert_error("chain(\"x\")", function() atempo.chain("x") end)
end)

-- ============================================================
-- Slice 8: exported stage-limit constants
-- ============================================================

run_test("STAGE_MIN == 0.5", function()
    mock.assert_equals(atempo.STAGE_MIN, 0.5, "min stage bound")
end)

run_test("STAGE_MAX == 2.0", function()
    mock.assert_equals(atempo.STAGE_MAX, 2.0, "max stage bound")
end)

-- ============================================================
-- Summary
-- ============================================================

print(string.format("\n%d passed, %d failed", passed, failed))
if #errors > 0 then
    print("\nFailures:")
    for _, e in ipairs(errors) do
        print("  " .. e.name .. ": " .. tostring(e.err))
    end
    os.exit(1)
end
