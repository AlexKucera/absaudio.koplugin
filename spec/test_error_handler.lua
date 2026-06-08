-- Error handler tests
-- Tests error_handler.lua public API: error type mapping, user messages
--
-- Run with: lua spec/test_error_handler.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

-- Stub KOReader dependencies
local last_info_message = nil
package.loaded["ui/widget/infomessage"] = {}
package.loaded["ui/widget/infomessage"].new = function(self, opts)
    last_info_message = opts.text
    return { text = opts.text }
end

local last_shown_widget = nil
package.loaded["ui/uimanager"] = {
    show = function(_, widget)
        last_shown_widget = widget
    end,
}

package.loaded["gettext"] = function(s) return s end

local mock = require("spec/test_helper")
local error_handler = require("error_handler")

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

-- Reset captured state between tests
local function reset()
    last_info_message = nil
    last_shown_widget = nil
end

-- ============================================================
-- Test: Error type to user message mapping
-- ============================================================
run_test("network error shows connection failure message", function()
    reset()
    error_handler.show("network", "Connection refused")
    assert(last_shown_widget ~= nil, "should show a widget")
    assert(last_info_message ~= nil, "should set message text")
    assert(string.find(last_info_message, "onnection") ~= nil or
           string.find(last_info_message, "network") ~= nil or
           string.find(last_info_message, "failed") ~= nil,
        "should contain connection-related text")
end)

run_test("auth error shows authentication failure message", function()
    reset()
    error_handler.show("auth", "Invalid token")
    assert(last_shown_widget ~= nil, "should show a widget")
    assert(string.find(last_info_message, "uth") ~= nil or
           string.find(last_info_message, "token") ~= nil or
           string.find(last_info_message, "credentials") ~= nil,
        "should contain auth-related text")
end)

run_test("filesystem error shows storage message", function()
    reset()
    error_handler.show("filesystem", "No space left on device")
    assert(last_shown_widget ~= nil, "should show a widget")
    assert(string.find(last_info_message, "torage") ~= nil or
           string.find(last_info_message, "file") ~= nil or
           string.find(last_info_message, "disk") ~= nil or
           string.find(last_info_message, "space") ~= nil,
        "should contain storage-related text")
end)

run_test("unknown error shows generic message", function()
    reset()
    error_handler.show("unknown", "Something went wrong")
    assert(last_shown_widget ~= nil, "should show a widget")
    assert(last_info_message ~= nil, "should set message text")
end)

run_test("error handler never crashes — nil details", function()
    reset()
    local ok, err = pcall(function()
        error_handler.show("network", nil)
    end)
    assert(ok, "error_handler.show should not crash with nil details: " .. tostring(err))
end)

run_test("error handler never crashes — nil type", function()
    reset()
    local ok, err = pcall(function()
        error_handler.show(nil, "something broke")
    end)
    assert(ok, "error_handler.show should not crash with nil type: " .. tostring(err))
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
