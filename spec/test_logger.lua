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
