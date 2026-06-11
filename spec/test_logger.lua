-- Logger wrapper tests
-- Tests abs_logger.lua public API: level filtering, message output
--
-- Run with: lua spec/test_logger.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

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

local mock = require("spec/test_helper")

-- Helper: create fresh stubs + load abs_logger module
local function load_fresh_logger(koreader_stub)
    package.loaded["logger"] = koreader_stub
    package.loaded["abs_logger"] = nil
    return require("abs_logger")
end

-- ============================================================
-- Test: Logger level filtering
-- ============================================================
run_test("verbose level logs all messages", function()
    local log = load_fresh_logger({
        dbg  = function() end,
        info = function() end,
        warn = function() end,
    })

    log.set_level("verbose")
    assert(log.should_log("verbose"), "verbose level should pass verbose messages")
    assert(log.should_log("info"), "verbose level should pass info messages")
    assert(log.should_log("warn"), "verbose level should pass warn messages")
end)

run_test("info level filters out verbose messages", function()
    local log = load_fresh_logger({
        dbg  = function() end,
        info = function() end,
        warn = function() end,
    })

    log.set_level("info")
    assert(not log.should_log("verbose"), "info level should NOT pass verbose messages")
    assert(log.should_log("info"), "info level should pass info messages")
    assert(log.should_log("warn"), "info level should pass warn messages")
end)

run_test("warn level filters out verbose and info messages", function()
    local log = load_fresh_logger({
        dbg  = function() end,
        info = function() end,
        warn = function() end,
    })

    log.set_level("warn")
    assert(not log.should_log("verbose"), "warn level should NOT pass verbose messages")
    assert(not log.should_log("info"), "warn level should NOT pass info messages")
    assert(log.should_log("warn"), "warn level should pass warn messages")
end)

run_test("verbose method delegates to KOReader dbg", function()
    local captured = nil
    local log = load_fresh_logger({
        dbg  = function(msg) captured = msg end,
        info = function() end,
        warn = function() end,
    })

    log.set_level("verbose")
    log.verbose("test verbose message")
    mock.assert_equals(captured, "[ABS] test verbose message", "verbose should call dbg with prefixed message")
end)

run_test("info method delegates to KOReader info", function()
    local captured = nil
    local log = load_fresh_logger({
        dbg  = function() end,
        info = function(msg) captured = msg end,
        warn = function() end,
    })

    log.set_level("info")
    log.info("test info message")
    mock.assert_equals(captured, "[ABS] test info message", "info should call logger.info with prefixed message")
end)

run_test("warn method delegates to KOReader warn", function()
    local captured = nil
    local log = load_fresh_logger({
        dbg  = function() end,
        info = function() end,
        warn = function(msg) captured = msg end,
    })

    log.set_level("warn")
    log.warn("test warn message")
    mock.assert_equals(captured, "[ABS] test warn message", "warn should call logger.warn with prefixed message")
end)

run_test("messages below configured level are suppressed", function()
    local called = false
    local log = load_fresh_logger({
        dbg  = function() called = true end,
        info = function() called = true end,
        warn = function() called = true end,
    })

    log.set_level("warn")

    called = false
    log.verbose("should not log")
    assert(not called, "verbose should be suppressed at warn level")

    called = false
    log.info("should not log")
    assert(not called, "info should be suppressed at warn level")
end)

-- ============================================================
-- Test: Fallback when KOReader logger is absent
-- ============================================================
run_test("loads successfully when logger module is absent", function()
    -- Remove logger from package.loaded so require fails
    package.loaded["logger"] = nil
    package.loaded["abs_logger"] = nil

    -- This should NOT crash — pcall guard with fallback
    local ok, log = pcall(require, "abs_logger")
    assert(ok, "abs_logger should load without crashing: " .. tostring(log))
    assert(type(log) == "table", "fallback logger should be a table")
    assert(type(log.info) == "function", "fallback logger should have info method")
    assert(type(log.warn) == "function", "fallback logger should have warn method")
    assert(type(log.verbose) == "function", "fallback logger should have verbose method")
end)

-- Helper for error messages (used in tests below)
local function concat_table(t)
    local parts = {}
    for _, v in ipairs(t) do table.insert(parts, tostring(v)) end
    return table.concat(parts, ", ")
end

run_test("fallback logger outputs [ABS] prefixed messages via print", function()
    -- Capture print output
    local printed = {}
    local _print = print
    print = function(msg) table.insert(printed, msg) end

    package.loaded["logger"] = nil
    package.loaded["abs_logger"] = nil
    local log = require("abs_logger")

    log.set_level("verbose")
    log.info("fallback test message")
    log.warn("fallback warn message")
    log.verbose("fallback verbose message")

    -- Restore print
    print = _print

    -- At least one message should have [ABS] prefix
    local found_abs = false
    for _, msg in ipairs(printed) do
        if string.find(msg, "[ABS]", 1, true) then
            found_abs = true
        end
    end
    assert(found_abs, "fallback messages should contain [ABS] prefix, got: " .. concat_table(printed))
end)

run_test("fallback logger respects level filtering", function()
    local printed = {}
    local _print = print
    print = function(msg) table.insert(printed, msg) end

    package.loaded["logger"] = nil
    package.loaded["abs_logger"] = nil
    local log = require("abs_logger")

    log.set_level("warn")
    log.verbose("should not print")
    log.info("should not print either")
    log.warn("this should print")

    print = _print

    -- Only 1 message (the warn)
    assert(#printed == 1, "warn level should produce exactly 1 output, got " .. #printed)
    assert(string.find(printed[1], "this should print", 1, true), "output should be the warn message")
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
