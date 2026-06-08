-- Test helper: lightweight mock framework for KOReader runtime dependencies
-- Usage: local mock = require("spec/test_helper")

local mock = {}

--- Create a mock LuaSettings that mimics KOReader's luasettings API
-- backed by a plain Lua table (no file I/O)
function mock.create_lua_settings(initial_data)
    local data = initial_data or {}
    local settings = {
        _data = data,
    }

    function settings:readSetting(key, default)
        if self._data[key] ~= nil then
            return self._data[key]
        end
        return default
    end

    function settings:saveSetting(key, value)
        self._data[key] = value
    end

    function settings:flush()
        -- no-op for testing
    end

    function settings:close()
        -- no-op for testing
    end

    function settings:isTrue(key)
        return self._data[key] == true
    end

    function settings:isFalse(key)
        return self._data[key] == false
    end

    function settings:nilOrFalse(key)
        return self._data[key] == nil or self._data[key] == false
    end

    return settings
end

--- Create a mock logger that captures log messages
function mock.create_logger()
    local logs = {
        verbose = {},
        info = {},
        warn = {},
    }
    local logger = {
        _logs = logs,
    }
    function logger:verbose(msg) table.insert(logs.verbose, msg) end
    function logger:info(msg)    table.insert(logs.info, msg) end
    function logger:warn(msg)    table.insert(logs.warn, msg) end
    return logger
end

--- Assert helpers
function mock.assert_contains(t, key)
    assert(t[key] ~= nil, string.format("Expected key '%s' to exist in table", key))
end

function mock.assert_equals(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s\nExpected: %s\nActual:   %s",
            message or "Assertion failed",
            tostring(expected),
            tostring(actual)))
    end
end

return mock
