-- PCM byte-buffer tests
-- Mutable PCM storage (wraps absaudio/ring_buffer index math) for absaudio.koplugin.
--
-- Covers the shared byte buffer between the FFmpeg decode producer and the ALSA
-- output pump: write/read with wraparound, overrun/underrun, capacity queries.
--
-- Run with: luajit spec/test_pcm_buffer.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local pcm_buffer = require("absaudio/pcm_buffer")
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
    return err
end

-- ============================================================
-- Slice 1: new() — capacity, initial fill/free, empty/full
-- ============================================================

run_test("new(1024) → capacity 1024, fill 0, free 1024, empty true, full false", function()
    local b = pcm_buffer.new(1024)
    mock.assert_equals(b:capacity(), 1024, "capacity")
    mock.assert_equals(b:fill(), 0, "initial fill")
    mock.assert_equals(b:free(), 1024, "initial free")
    mock.assert_equals(b:empty(), true, "empty when nothing written")
    mock.assert_equals(b:full(), false, "not full initially")
end)

-- ============================================================
-- Slice 2: new() — capacity validation (errors)
-- ============================================================

run_test("new(0) → errors", function()
    assert_error("new(0)", function() pcm_buffer.new(0) end)
end)

run_test("new(-1) → errors", function()
    assert_error("new(-1)", function() pcm_buffer.new(-1) end)
end)

run_test("new('x') → errors (non-number)", function()
    assert_error("new('x')", function() pcm_buffer.new("x") end)
end)

-- ============================================================
-- Slice 3: write(data) — fill increases, free decreases, not empty after
-- ============================================================

run_test("write('ABCD') → fill 4, free -4, empty false", function()
    local b = pcm_buffer.new(1024)
    b:write("ABCD")
    mock.assert_equals(b:fill(), 4, "fill increased by #data")
    mock.assert_equals(b:free(), 1020, "free decreased by #data")
    mock.assert_equals(b:empty(), false, "not empty after write")
end)

-- ============================================================
-- Slice 4: read(n) — returns the EXACT bytes written
-- ============================================================

run_test("write('ABCD') then read(4) → 'ABCD'", function()
    local b = pcm_buffer.new(1024)
    b:write("ABCD")
    mock.assert_equals(b:read(4), "ABCD", "exact bytes returned")
end)

-- ============================================================
-- Slice 5: sequential write/read/write (no wrap) round-trips
-- ============================================================

run_test("write 'AB' read 2 write 'CD' read 2 → 'AB','CD' in order", function()
    local b = pcm_buffer.new(1024)
    b:write("AB")
    mock.assert_equals(b:read(2), "AB", "first read")
    b:write("CD")
    mock.assert_equals(b:read(2), "CD", "second read")
    mock.assert_equals(b:fill(), 0, "empty after full round-trip")
end)

-- ============================================================
-- Slice 6: wraparound — backing array wraps around capacity
-- ============================================================

run_test("wraparound: cap 4, write 'AB' read 2 write 'CD' (slot wraps 0) read 2 → 'CD'", function()
    local b = pcm_buffer.new(4)
    b:write("AB")
    mock.assert_equals(b:read(2), "AB", "first read")
    b:write("CD")  -- write_slot wraps from 2 back to 0
    mock.assert_equals(b:read(2), "CD", "second read wraps correctly")
end)

run_test("wraparound: cap 4, write 'AB' read 2 write 'ABCD' (wraps 2→3→0→1) read 4 → 'ABCD'", function()
    local b = pcm_buffer.new(4)
    b:write("AB")
    b:read(2)  -- drain, free=4
    b:write("ABCD")  -- fills exactly, write_slot starts at 2, wraps to 0
    mock.assert_equals(b:full(), true, "buffer is full")
    mock.assert_equals(b:read(4), "ABCD", "single write wrapping itself round-trips")
end)

-- ============================================================
-- Slice 7: write() errors on overrun
-- ============================================================

run_test("overrun: cap 4, write 5 bytes → errors with 'overrun'", function()
    local b = pcm_buffer.new(4)
    local err = assert_error("write overrun", function() b:write("ABCDE") end)
    mock.assert_equals(tostring(err):find("overrun") ~= nil, true,
        "error message contains 'overrun'")
end)

-- ============================================================
-- Slice 8: read() errors on underrun
-- ============================================================

run_test("underrun: cap 4, write 'AB' read 5 → errors with 'underrun'", function()
    local b = pcm_buffer.new(4)
    b:write("AB")
    local err = assert_error("read underrun", function() b:read(5) end)
    mock.assert_equals(tostring(err):find("underrun") ~= nil, true,
        "error message contains 'underrun'")
end)

-- ============================================================
-- Slice 9: can_write(n)/can_read(n) gate at boundaries
-- ============================================================

run_test("can_write/can_read boundaries: cap 4, write 2", function()
    local b = pcm_buffer.new(4)
    b:write("AB")
    mock.assert_equals(b:can_write(2), true, "free=2 → can_write(2) ok")
    mock.assert_equals(b:can_write(3), false, "free=2 → can_write(3) overrun")
    mock.assert_equals(b:can_read(2), true, "fill=2 → can_read(2) ok")
    mock.assert_equals(b:can_read(3), false, "fill=2 → can_read(3) underrun")
end)

-- ============================================================
-- Slice 10: full() true at capacity; can_write(1) false when full
-- ============================================================

run_test("full buffer: cap 4 write 4 → full true, can_write(1) false", function()
    local b = pcm_buffer.new(4)
    b:write("ABCD")
    mock.assert_equals(b:full(), true, "buffer is full")
    mock.assert_equals(b:free(), 0, "no free space")
    mock.assert_equals(b:can_write(1), false, "cannot write 1 more")
end)

-- ============================================================
-- Slice 11: clear() resets to empty; subsequent writes start at slot 0
-- ============================================================

run_test("clear() resets fill/free and writes restart at slot 0", function()
    local b = pcm_buffer.new(4)
    b:write("AB")
    mock.assert_equals(b:fill(), 2, "fill 2 before clear")
    b:clear()
    mock.assert_equals(b:fill(), 0, "fill 0 after clear")
    mock.assert_equals(b:free(), 4, "free=capacity after clear")
    mock.assert_equals(b:empty(), true, "empty after clear")
    b:write("CD")
    mock.assert_equals(b:read(2), "CD", "write after clear starts at slot 0")
end)

-- ============================================================
-- Slice 12: larger interleaved round-trip (write/read/write with wrap)
-- ============================================================

run_test("cap 16: write 10, read 4, write 8 (wraps), read 14 → concatenated in order", function()
    local b = pcm_buffer.new(16)
    b:write("0123456789")       -- fill 10
    mock.assert_equals(b:read(4), "0123", "first 4 bytes")
    b:write("abcdefgh")         -- fill 14 (wraps around capacity)
    mock.assert_equals(b:fill(), 14, "fill 14 after second write")
    local rest = b:read(14)     -- read all remaining
    mock.assert_equals(rest, "456789abcdefgh",
        "remaining bytes are first-write-tail + second-write in order")
    mock.assert_equals(b:empty(), true, "empty after draining")
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
