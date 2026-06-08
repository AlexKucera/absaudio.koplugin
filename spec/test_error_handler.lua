-- Error handler tests
-- Tests error_handler.lua public API: error type mapping, HTTP status codes, user messages
--
-- Run with: luajit spec/test_error_handler.lua

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
-- Test: Error type to user message mapping (legacy API)
-- ============================================================
run_test("network error shows connection failure message", function()
    reset()
    error_handler.show("network", "Connection refused")
    assert(last_shown_widget ~= nil, "should show a widget")
    assert(last_info_message ~= nil, "should set message text")
    assert(string.find(last_info_message, "onnection") ~= nil or
           string.find(last_info_message, "network") ~= nil or
           string.find(last_info_message, "failed") ~= nil or
           string.find(last_info_message, "server") ~= nil,
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
-- Test: HTTP status code classification
-- ============================================================
run_test("classify_http_status maps 401 to auth", function()
    local err_type, msg = error_handler.classify_http_status(401)
    mock.assert_equals(err_type, "auth", "401 should be auth type")
    assert(msg ~= nil and msg ~= "", "should return a message")
end)

run_test("classify_http_status maps 403 to auth", function()
    local err_type, msg = error_handler.classify_http_status(403)
    mock.assert_equals(err_type, "auth", "403 should be auth type")
    assert(msg ~= nil and msg ~= "", "should return a message")
end)

run_test("classify_http_status maps 404 to not_found", function()
    local err_type, msg = error_handler.classify_http_status(404)
    mock.assert_equals(err_type, "not_found", "404 should be not_found type")
    assert(string.find(msg, "not found") ~= nil or string.find(msg, "removed") ~= nil,
        "404 message should mention not found or removed")
end)

run_test("classify_http_status maps 500 to server", function()
    local err_type, msg = error_handler.classify_http_status(500)
    mock.assert_equals(err_type, "server", "500 should be server type")
    assert(msg ~= nil and msg ~= "", "should return a message")
end)

run_test("classify_http_status maps 503 to server", function()
    local err_type, msg = error_handler.classify_http_status(503)
    mock.assert_equals(err_type, "server", "503 should be server type")
end)

run_test("classify_http_status maps 429 to api (rate limit)", function()
    local err_type, msg = error_handler.classify_http_status(429)
    mock.assert_equals(err_type, "api", "429 should be api type")
end)

run_test("classify_http_status maps 400 to api (client error)", function()
    local err_type, msg = error_handler.classify_http_status(400)
    mock.assert_equals(err_type, "api", "400 should be api type")
end)

-- ============================================================
-- Test: from_api_error builds messages from API error tables
-- ============================================================
run_test("from_api_error with 401 status returns auth message", function()
    local msg = error_handler.from_api_error({type = "auth", status_code = 401, message = "Unauthorized"})
    assert(msg ~= nil, "should return a message")
    assert(string.find(msg, "token") ~= nil or string.find(msg, "Token") ~= nil or
           string.find(msg, "credentials") ~= nil,
        "should contain auth-related text")
end)

run_test("from_api_error with 404 status returns not_found message", function()
    local msg = error_handler.from_api_error({type = "not_found", status_code = 404})
    assert(msg ~= nil, "should return a message")
end)

run_test("from_api_error with 500 status returns server message", function()
    local msg = error_handler.from_api_error({type = "server", status_code = 500})
    assert(msg ~= nil, "should return a message")
end)

run_test("from_api_error without status_code falls back to type mapping", function()
    local msg = error_handler.from_api_error({type = "network", message = "host not found"})
    assert(msg ~= nil, "should return a message")
    assert(string.find(msg, "onnection") ~= nil or string.find(msg, "network") ~= nil,
        "should contain network-related text")
end)

run_test("from_api_error with nil input returns unknown message", function()
    local msg = error_handler.from_api_error(nil)
    assert(msg ~= nil, "should return a message for nil input")
end)

run_test("from_api_error with string input returns unknown message", function()
    local msg = error_handler.from_api_error("some error string")
    assert(msg ~= nil, "should return a message for string input")
end)

-- ============================================================
-- Test: show_api_error displays dialog from API error
-- ============================================================
run_test("show_api_error shows dialog for API error table", function()
    reset()
    error_handler.show_api_error({type = "auth", status_code = 401, message = "Unauthorized"})
    assert(last_shown_widget ~= nil, "should show a widget")
    assert(last_info_message ~= nil, "should set message text")
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
