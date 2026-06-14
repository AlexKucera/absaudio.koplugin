-- Ring-buffer index-math tests
-- Pure-logic ring-buffer cursor arithmetic for absaudio.koplugin.
--
-- Covers acceptance criteria from issue #32 (audio slice A):
--   fill level, advance (write/read), wraparound, overrun detection,
--   underrun detection across a range of capacities and chunk sizes.
--
-- Run with: luajit spec/test_ring_buffer.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local rb = require("absaudio/ring_buffer")
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
    local ok, err = pcall(fn)
    mock.assert_equals(ok, false, name .. " should error")
end

-- ============================================================
-- Slice 1: new() — capacity, initial fill/free, empty/full
-- ============================================================

run_test("new(1024) → fill 0, free 1024, empty true, full false", function()
    local s = rb.new(1024)
    mock.assert_equals(rb.fill(s), 0, "initial fill")
    mock.assert_equals(rb.free(s), 1024, "initial free")
    mock.assert_equals(rb.empty(s), true, "empty when nothing written")
    mock.assert_equals(rb.full(s), false, "not full initially")
end)

-- ============================================================
-- Slice 2: new() — capacity validation (errors)
-- ============================================================

run_test("new(0) → errors", function()
    assert_error("new(0)", function() rb.new(0) end)
end)

run_test("new(-1) → errors", function()
    assert_error("new(-1)", function() rb.new(-1) end)
end)

-- ============================================================
-- Slice 3: write(n) — returns new state, original unchanged (immutability)
-- ============================================================

run_test("write(400) from new(1000) → fill 400, free 600, not empty/full; original unchanged", function()
    local s = rb.new(1000)
    local s2 = rb.write(s, 400)
    mock.assert_equals(rb.fill(s2), 400, "fill after write")
    mock.assert_equals(rb.free(s2), 600, "free after write")
    mock.assert_equals(rb.empty(s2), false, "not empty after write")
    mock.assert_equals(rb.full(s2), false, "not full after write")
    -- Immutability: original state untouched
    mock.assert_equals(s.write, 0, "original write counter unchanged")
    mock.assert_equals(rb.fill(s), 0, "original fill still 0")
end)

-- ============================================================
-- Slice 4: fill accumulates across chained writes
-- ============================================================

run_test("chained writes accumulate fill (100 + 50 → 150)", function()
    local s = rb.new(1000)
    s = rb.write(s, 100)
    s = rb.write(s, 50)
    mock.assert_equals(rb.fill(s), 150, "fill accumulates")
end)

-- ============================================================
-- Slice 5: read(n) — returns new state, original unchanged (immutability)
-- ============================================================

run_test("read(200) after write(400) → fill 200; original-before-read still 400", function()
    local s = rb.new(1000)
    s = rb.write(s, 400)
    local s2 = rb.read(s, 200)
    mock.assert_equals(rb.fill(s2), 200, "fill after read")
    -- Immutability: state before read untouched
    mock.assert_equals(rb.fill(s), 400, "original fill still 400")
end)

-- ============================================================
-- Slice 6: full buffer — write to capacity, then full/free/can_write
-- ============================================================

run_test("write(1000) from new(1000) → full true, free 0, can_write(1) false", function()
    local s = rb.new(1000)
    s = rb.write(s, 1000)
    mock.assert_equals(rb.full(s), true, "buffer is full")
    mock.assert_equals(rb.free(s), 0, "no free space")
    mock.assert_equals(rb.can_write(s, 1), false, "cannot write 1 more (overrun)")
end)

-- ============================================================
-- Slice 7: can_write overrun boundary
-- ============================================================

run_test("can_write boundary: write 800/1000 → can_write(300) false, can_write(200) true", function()
    local s = rb.new(1000)
    s = rb.write(s, 800)
    mock.assert_equals(rb.can_write(s, 300), false, "free=200 < 300 → overrun")
    mock.assert_equals(rb.can_write(s, 200), true, "free=200 >= 200 → ok")
end)

-- ============================================================
-- Slice 8: can_read underrun boundary + empties out
-- ============================================================

run_test("can_read boundary: write 200 → can_read(300) false, can_read(200) true; then empty", function()
    local s = rb.new(1000)
    s = rb.write(s, 200)
    mock.assert_equals(rb.can_read(s, 300), false, "fill=200 < 300 → underrun")
    mock.assert_equals(rb.can_read(s, 200), true, "fill=200 >= 200 → ok")
    s = rb.read(s, 200)
    mock.assert_equals(rb.can_read(s, 1), false, "empty after draining → underrun")
end)

-- ============================================================
-- Slice 9: write() errors on overrun
-- ============================================================

run_test("write(300) after write(800) of 1000 → errors (overrun)", function()
    local s = rb.new(1000)
    s = rb.write(s, 800)
    assert_error("write overrun", function() rb.write(s, 300) end)
end)

-- ============================================================
-- Slice 10: read() errors on underrun
-- ============================================================

run_test("read(200) after write(100) → errors (underrun)", function()
    local s = rb.new(1000)
    s = rb.write(s, 100)
    assert_error("read underrun", function() rb.read(s, 200) end)
end)

-- ============================================================
-- Slice 11: wraparound — write_slot across a full buffer cycle
-- ============================================================

run_test("write_slot wraps: 0 → 600 → 0 (full) → 400 (after read+write past cap)", function()
    local s = rb.new(1000)
    mock.assert_equals(rb.write_slot(s), 0, "empty: slot 0")
    s = rb.write(s, 600)
    mock.assert_equals(rb.write_slot(s), 600, "after write 600: slot 600")
    s = rb.write(s, 400)  -- now full, write=1000
    mock.assert_equals(rb.write_slot(s), 0, "full (write=1000): wraps to slot 0")
    s = rb.read(s, 400)   -- read=400, frees space
    mock.assert_equals(rb.read_slot(s), 400, "read slot 400")
    s = rb.write(s, 400)  -- write=1400
    mock.assert_equals(rb.write_slot(s), 400, "write=1400: wraps to slot 400")
end)

-- ============================================================
-- Slice 12: wraparound — read_slot across a full drain cycle
-- ============================================================

run_test("read_slot wraps: write 1000, read 400 → slot 400; read 600 → slot 0", function()
    local s = rb.new(1000)
    s = rb.write(s, 1000)
    s = rb.read(s, 400)
    mock.assert_equals(rb.read_slot(s), 400, "read=400: slot 400")
    s = rb.read(s, 600)
    mock.assert_equals(rb.read_slot(s), 0, "read=1000: wraps to slot 0")
end)

-- ============================================================
-- Slice 13: round-trip to empty — counters advance, not reset
-- ============================================================

run_test("write 750 + read 750 → empty but write==750, read==750 (not reset)", function()
    local s = rb.new(1000)
    s = rb.write(s, 750)
    s = rb.read(s, 750)
    mock.assert_equals(rb.fill(s), 0, "fill 0")
    mock.assert_equals(rb.empty(s), true, "empty")
    mock.assert_equals(s.write, 750, "absolute write counter advanced (not reset)")
    mock.assert_equals(s.read, 750, "absolute read counter advanced (not reset)")
end)

-- ============================================================
-- Slice 14: large capacity + chunk (parametric scale check)
-- ============================================================

run_test("new(65536) write(16384) → fill 16384, free 49152, write_slot 16384", function()
    local s = rb.new(65536)
    s = rb.write(s, 16384)
    mock.assert_equals(rb.fill(s), 16384, "fill 16384")
    mock.assert_equals(rb.free(s), 49152, "free 49152")
    mock.assert_equals(rb.write_slot(s), 16384, "write_slot 16384")
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
