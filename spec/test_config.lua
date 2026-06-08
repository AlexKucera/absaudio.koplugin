-- Config manager tests
-- Tests config.lua public API: defaults, read, write, validation
--
-- Run with: lua spec/test_config.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

-- Stub KOReader dependencies that config.lua requires
-- These must be defined BEFORE requiring config.lua
local mock_settings = nil
local mock_settings_path = nil

-- Stub luasettings module
package.loaded["luasettings"] = {}
package.loaded["luasettings"].open = function(self, path)
    mock_settings_path = path
    return mock_settings
end

-- Stub DataStorage
package.loaded["datastorage"] = {
    getSettingsDir = function()
        return "/tmp/koreader-test/settings"
    end,
}

-- Stub util
package.loaded["util"] = {}

local mock = require("spec/test_helper")
local config = require("config")

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
-- Test: Config returns correct defaults for new config
-- ============================================================
run_test("new config returns correct default values", function()
    mock_settings = mock.create_lua_settings({})

    -- config.init() should populate defaults when settings are empty
    config.init()

    mock.assert_equals(config.get("preferred_format"), "m4b", "default preferred_format should be m4b")
    mock.assert_equals(config.get("log_level"), "verbose", "default log_level should be verbose")
    mock.assert_equals(config.get("server"), nil, "server should be nil when not set")
    mock.assert_equals(config.get("token"), nil, "token should be nil when not set")
    mock.assert_equals(config.get("download_dir"), nil, "download_dir should be nil when not set")
end)

run_test("config path uses LuaSettings under KOReader settings dir", function()
    mock_settings = mock.create_lua_settings({})

    config.init()

    assert(mock_settings_path ~= nil, "LuaSettings:open should have been called")
    assert(type(mock_settings_path) == "string", "config path should be a string, got " .. type(mock_settings_path))
    assert(string.find(mock_settings_path, "absaudio"), "config path should contain 'absaudio'")
    assert(string.find(mock_settings_path, "%.lua$"), "config path should end with .lua")
end)

-- ============================================================
-- Test: Config read/write round-trip
-- ============================================================
run_test("write then read returns written value", function()
    mock_settings = mock.create_lua_settings({})

    config.init()

    config.set("server", "https://abs.example.com")
    config.set("token", "my-secret-token")
    config.set("download_dir", "/mnt/ext1/audiobooks")

    mock.assert_equals(config.get("server"), "https://abs.example.com", "server round-trip")
    mock.assert_equals(config.get("token"), "my-secret-token", "token round-trip")
    mock.assert_equals(config.get("download_dir"), "/mnt/ext1/audiobooks", "download_dir round-trip")
end)

run_test("set overwrites previous value", function()
    mock_settings = mock.create_lua_settings({})

    config.init()

    config.set("server", "https://old.example.com")
    config.set("server", "https://new.example.com")

    mock.assert_equals(config.get("server"), "https://new.example.com", "server should be updated")
end)

-- ============================================================
-- Test: Config validation
-- ============================================================
run_test("is_configured returns false when server is missing", function()
    mock_settings = mock.create_lua_settings({})

    config.init()
    config.set("token", "some-token")

    mock.assert_equals(config.is_configured(), false, "should not be configured without server")
end)

run_test("is_configured returns false when token is missing", function()
    mock_settings = mock.create_lua_settings({})

    config.init()
    config.set("server", "https://abs.example.com")

    mock.assert_equals(config.is_configured(), false, "should not be configured without token")
end)

run_test("is_configured returns true when server and token are set", function()
    mock_settings = mock.create_lua_settings({})

    config.init()
    config.set("server", "https://abs.example.com")
    config.set("token", "my-secret-token")

    mock.assert_equals(config.is_configured(), true, "should be configured with server + token")
end)

run_test("validate_server_url rejects empty string", function()
    mock_settings = mock.create_lua_settings({})
    config.init()

    local ok, err = config.validate_server_url("")
    mock.assert_equals(ok, false, "empty URL should be invalid")
    assert(err ~= nil, "should return an error message")
end)

run_test("validate_server_url rejects URL without scheme", function()
    mock_settings = mock.create_lua_settings({})
    config.init()

    local ok, err = config.validate_server_url("abs.example.com")
    mock.assert_equals(ok, false, "URL without scheme should be invalid")
end)

run_test("validate_server_url accepts valid https URL", function()
    mock_settings = mock.create_lua_settings({})
    config.init()

    local ok, err = config.validate_server_url("https://abs.example.com")
    mock.assert_equals(ok, true, "valid https URL should pass")
end)

run_test("validate_server_url accepts valid http URL", function()
    mock_settings = mock.create_lua_settings({})
    config.init()

    local ok, err = config.validate_server_url("http://192.168.1.100:13378")
    mock.assert_equals(ok, true, "valid http URL should pass")
end)

run_test("validate_server_url strips trailing slash", function()
    mock_settings = mock.create_lua_settings({})
    config.init()

    config.set("server", "https://abs.example.com/")
    mock.assert_equals(config.get("server"), "https://abs.example.com", "trailing slash should be stripped")
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
