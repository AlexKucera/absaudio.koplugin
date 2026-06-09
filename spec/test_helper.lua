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

--- Create a mock HTTP transport stub for api.lua tests
-- @param responses table  array of {status_code=N, body="..."} or {error="msg"}
-- @return table  transport stub with request() method and _call_log
function mock.create_transport_stub(responses)
    responses = responses or {}
    local call_log = {}
    local response_idx = 1

    local function request(req)
        -- Log the call
        table.insert(call_log, {
            url = req.url,
            method = req.method,
            headers = req.headers or {},
        })

        -- Get the next response
        -- Get the next response (repeat last response if exhausted)
        local resp = responses[response_idx] or responses[#responses] or { status_code = 200, body = "{}" }
        if response_idx <= #responses then
            response_idx = response_idx + 1
        end

        -- Handle error responses (connection failures)
        if resp.error then
            return 1, resp.error  -- socket.http returns (1, error_string) on failure
        end

        -- Write body to sink if present
        if resp.body and req.sink then
            req.sink(resp.body)
        end

        -- Return status code
        return 1, resp.status_code
    end

    return {
        request = request,
        _call_log = call_log,
    }
end

return mock