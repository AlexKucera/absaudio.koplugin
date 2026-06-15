-- audio_ffi module tests (issue #34, audio slice C)
--
-- The guarded FFI shim for the FFmpeg+ALSA audio backend. Tests verify:
--   * is_available() returns false on the dev Mac (libaudio-engine.so absent)
--   * is_available() NEVER throws — guarded FFI access
--   * is_available() is memoized (stable across repeated calls)
--   * _set_probe_override() controls the probe result for tests
--   * KEY_SYMBOLS is a non-empty table of FFmpeg function names
--   * Requiring the module twice is stable (guarded cdefs don't error)
--
-- Run with: luajit spec/test_audio_ffi.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded["abs_logger"] = {
    verbose = function() end,
    info = function() end,
    warn = function() end,
}

local mock = require("spec/test_helper")
local audio_ffi = require("absaudio/audio_ffi")

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
-- Slice 1: is_available() returns false on the dev Mac
-- ============================================================

run_test("is_available(): returns false on the dev Mac (libaudio-engine absent)", function()
    audio_ffi._set_probe_override(nil)  -- restore default probe
    mock.assert_equals(audio_ffi.is_available(), false,
        "guarded FFI probe returns false when the toolkit lib is absent")
end)

-- ============================================================
-- Slice 2: is_available() NEVER throws (even though ffi IS present)
-- ============================================================

run_test("is_available(): never throws even though luajit ffi is present", function()
    local has_ffi = pcall(require, "ffi")
    mock.assert_equals(has_ffi, true, "precondition: luajit ffi IS present in tests")
    audio_ffi._set_probe_override(nil)  -- default probe
    local ok, result = pcall(audio_ffi.is_available)
    mock.assert_equals(ok, true, "probe does not throw")
    mock.assert_equals(result, false, "returns false on dev")
end)

-- ============================================================
-- Slice 3: is_available() is memoized (stable across repeated calls)
-- ============================================================

run_test("is_available(): memoized — repeated calls return the same value", function()
    audio_ffi._set_probe_override(nil)
    local r1 = audio_ffi.is_available()
    local r2 = audio_ffi.is_available()
    local r3 = audio_ffi.is_available()
    mock.assert_equals(r1, r2, "call 1 == call 2")
    mock.assert_equals(r2, r3, "call 2 == call 3 (memoized)")
    mock.assert_equals(r1, false, "false on dev")
end)

-- ============================================================
-- Slice 4: _set_probe_override(fn) forces true; nil restores → false
-- ============================================================

run_test("_set_probe_override(fn) forces true (device simulation)", function()
    audio_ffi._set_probe_override(function() return true end)
    mock.assert_equals(audio_ffi.is_available(), true, "override forces available")
    audio_ffi._set_probe_override(nil)  -- restore
    mock.assert_equals(audio_ffi.is_available(), false, "restored default → false")
end)

-- ============================================================
-- Slice 5: KEY_SYMBOLS is a non-empty table of FFmpeg function names
-- ============================================================

run_test("KEY_SYMBOLS: non-empty table containing avformat_open_input", function()
    mock.assert_equals(type(audio_ffi.KEY_SYMBOLS), "table", "KEY_SYMBOLS is a table")
    mock.assert_equals(#audio_ffi.KEY_SYMBOLS > 0, true, "KEY_SYMBOLS is non-empty")
    local has_open = false
    for _, sym in ipairs(audio_ffi.KEY_SYMBOLS) do
        if sym == "avformat_open_input" then has_open = true end
    end
    mock.assert_equals(has_open, true, "contains avformat_open_input")
end)

-- ============================================================
-- Slice 6: Requiring the module twice is stable (guarded cdefs)
-- ============================================================

run_test("require twice is stable: cdefs are guarded, no crash on re-require", function()
    audio_ffi._set_probe_override(nil)
    mock.assert_equals(audio_ffi.is_available(), false, "first require: false on dev")
    -- The cdef guards mean a second require (package.loaded cache hit) is fine;
    -- even a fresh probe invocation re-runs declare_cdefs without erroring.
    local m2 = require("absaudio/audio_ffi")
    mock.assert_equals(m2, audio_ffi, "second require returns the same cached module")
    m2._set_probe_override(nil)
    mock.assert_equals(m2.is_available(), false, "second require: still false on dev")
end)

-- ============================================================
-- Slice 7: override simulating 'some key symbol missing' returns false
-- ============================================================

run_test("_set_probe_override simulating 'symbol missing' returns false", function()
    -- The override fully controls the result — a fn returning false simulates
    -- a device where a key symbol is absent.
    audio_ffi._set_probe_override(function() return false end)
    mock.assert_equals(audio_ffi.is_available(), false,
        "override returning false → false (simulates missing symbol)")
    audio_ffi._set_probe_override(nil)  -- restore
end)

-- ============================================================
-- Slice 8: override returning true → true; restore → false
-- ============================================================

run_test("override is the single source of truth when set", function()
    audio_ffi._set_probe_override(function() return true end)
    mock.assert_equals(audio_ffi.is_available(), true, "override true → true")
    audio_ffi._set_probe_override(nil)  -- restore
    mock.assert_equals(audio_ffi.is_available(), false, "restored → false on dev")
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
