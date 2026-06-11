-- API transport seam tests
-- Tests api.lua with injected transport stub: all 9 endpoints,
-- retry behavior, error classification, JSON parsing, is_configured()
--
-- Run with: luajit spec/test_api.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

-- ============================================================
-- Minimal JSON module (for test environment without dkjson/cjson)
-- ============================================================
local json = {}

local function decode_error(pos, msg)
    return nil, pos, "json decode error at position " .. pos .. ": " .. msg
end

function json.decode(str)
    if type(str) ~= "string" then
        return nil, nil, "expected string"
    end
    local pos = 1

    local function skip_ws()
        pos = (str:match("^%s*()", pos))
    end

    local function parse_value()
        skip_ws()
        if pos > #str then error("unexpected end of input") end
        local c = str:sub(pos, pos)
        if c == "{" then
            return parse_object()
        elseif c == "[" then
            return parse_array()
        elseif c == '"' then
            return parse_string()
        elseif c == "t" or c == "f" then
            return parse_boolean()
        elseif c == "n" then
            return parse_null()
        elseif c == "-" or (c >= "0" and c <= "9") then
            return parse_number()
        else
            error("unexpected character '" .. c .. "' at position " .. pos)
        end
    end

    function parse_object()
        pos = pos + 1 -- skip {
        local obj = {}
        skip_ws()
        if str:sub(pos, pos) == "}" then
            pos = pos + 1
            return obj
        end
        while true do
            skip_ws()
            local key = parse_string()
            skip_ws()
            if str:sub(pos, pos) ~= ":" then
                error("expected ':' at position " .. pos)
            end
            pos = pos + 1
            local val = parse_value()
            obj[key] = val
            skip_ws()
            local sep = str:sub(pos, pos)
            if sep == "}" then
                pos = pos + 1
                return obj
            elseif sep == "," then
                pos = pos + 1
            else
                error("expected ',' or '}' at position " .. pos)
            end
        end
    end

    function parse_array()
        pos = pos + 1 -- skip [
        local arr = {}
        skip_ws()
        if str:sub(pos, pos) == "]" then
            pos = pos + 1
            return arr
        end
        while true do
            local val = parse_value()
            table.insert(arr, val)
            skip_ws()
            local sep = str:sub(pos, pos)
            if sep == "]" then
                pos = pos + 1
                return arr
            elseif sep == "," then
                pos = pos + 1
            else
                error("expected ',' or ']' at position " .. pos)
            end
        end
    end

    function parse_string()
        if str:sub(pos, pos) ~= '"' then
            error("expected '\"' at position " .. pos)
        end
        pos = pos + 1
        local result = {}
        while pos <= #str do
            local c = str:sub(pos, pos)
            if c == '"' then
                pos = pos + 1
                return table.concat(result)
            elseif c == "\\" then
                pos = pos + 1
                local esc = str:sub(pos, pos)
                if esc == "n" then
                    table.insert(result, "\n")
                elseif esc == "t" then
                    table.insert(result, "\t")
                elseif esc == "r" then
                    table.insert(result, "\r")
                elseif esc == '"' then
                    table.insert(result, '"')
                elseif esc == "\\" then
                    table.insert(result, "\\")
                elseif esc == "/" then
                    table.insert(result, "/")
                else
                    table.insert(result, esc)
                end
                pos = pos + 1
            else
                table.insert(result, c)
                pos = pos + 1
            end
        end
        error("unterminated string")
    end

    function parse_number()
        local num_start = pos
        if str:sub(pos, pos) == "-" then pos = pos + 1 end
        while pos <= #str and str:sub(pos, pos):match("%d") do
            pos = pos + 1
        end
        if pos <= #str and str:sub(pos, pos) == "." then
            pos = pos + 1
            while pos <= #str and str:sub(pos, pos):match("%d") do
                pos = pos + 1
            end
        end
        if pos <= #str and (str:sub(pos, pos) == "e" or str:sub(pos, pos) == "E") then
            pos = pos + 1
            if pos <= #str and (str:sub(pos, pos) == "+" or str:sub(pos, pos) == "-") then
                pos = pos + 1
            end
            while pos <= #str and str:sub(pos, pos):match("%d") do
                pos = pos + 1
            end
        end
        return tonumber(str:sub(num_start, pos - 1))
    end

    function parse_boolean()
        if str:sub(pos, pos + 3) == "true" then
            pos = pos + 4
            return true
        elseif str:sub(pos, pos + 4) == "false" then
            pos = pos + 5
            return false
        else
            error("invalid boolean at position " .. pos)
        end
    end

    function parse_null()
        if str:sub(pos, pos + 3) == "null" then
            pos = pos + 4
            return nil
        else
            error("invalid null at position " .. pos)
        end
    end

    local ok, result = pcall(parse_value)
    if ok then
        return result, nil, nil
    else
        return nil, nil, result
    end
end

function json.encode(val)
    if type(val) == "nil" then return "null" end
    if type(val) == "boolean" then return val and "true" or "false" end
    if type(val) == "number" then
        if val ~= val then return "null" end -- NaN
        if val >= math.huge then return "1e999" end
        if val <= -math.huge then return "-1e999" end
        return tostring(val)
    end
    if type(val) == "string" then
        return '"' .. val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\t', '\\t') .. '"'
    end
    if type(val) == "table" then
        -- Check if array
        local is_array = false
        local max_i = 0
        for k, _ in pairs(val) do
            if type(k) == "number" and k == math.floor(k) and k >= 1 then
                if k > max_i then max_i = k end
            end
        end
        is_array = (max_i > 0 and max_i == #val)

        if is_array then
            local parts = {}
            for i = 1, #val do
                table.insert(parts, json.encode(val[i]))
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, v in pairs(val) do
                if type(k) == "string" then
                    table.insert(parts, '"' .. k .. '":' .. json.encode(v))
                end
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

-- Register json module before requiring api
package.loaded["json"] = json

-- ============================================================
-- Test setup
-- ============================================================

-- Stub KOReader dependencies
package.loaded["logger"] = {
    dbg = function() end,
    info = function() end,
    warn = function() end,
}

package.loaded["abs_logger"] = {
    verbose = function() end,
    info = function() end,
    warn = function() end,
    set_level = function() end,
}

-- Provide ltn12 stub for test environment
package.loaded["ltn12"] = {
    sink = {
        table = function(t)
            return function(chunk)
                if chunk then table.insert(t, chunk) end
                return true
            end
        end,
    },
    source = {
        string = function(s)
            local done = false
            return function()
                if not done and s then
                    done = true
                    return s
                end
                return nil
            end
        end,
    },
}

local mock = require("spec/test_helper")
local api = require("api")

local passed = 0
local failed = 0
local errors = {}

-- Speed up retry tests by overriding os.time to skip busy-wait
local real_os_time = os.time
local fake_time_origin = 1000000
local function with_fast_time(fn)
    local fake_clock = fake_time_origin
    os.time = function()
        local t = fake_clock
        fake_clock = fake_clock + 100 -- jump 100s per call
        return t
    end
    local ok, err = pcall(fn)
    os.time = real_os_time
    if not ok then error(err) end
end

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
-- is_configured tests
-- ============================================================

run_test("is_configured returns false before init", function()
    api.init(nil, nil)
    mock.assert_equals(api.is_configured(), false, "should be false before init")
end)

run_test("is_configured returns true after init with valid args", function()
    local transport = mock.create_transport_stub()
    api.init("https://abs.example.com", "test-token", transport)
    mock.assert_equals(api.is_configured(), true, "should be true after valid init")
end)

run_test("is_configured returns false with empty url", function()
    local transport = mock.create_transport_stub()
    api.init("", "test-token", transport)
    mock.assert_equals(api.is_configured(), false, "should be false with empty url")
end)

run_test("is_configured returns false with empty token", function()
    local transport = mock.create_transport_stub()
    api.init("https://abs.example.com", "", transport)
    mock.assert_equals(api.is_configured(), false, "should be false with empty token")
end)

-- ============================================================
-- Endpoint tests (all 9)
-- ============================================================

run_test("getLibraries returns parsed libraries", function()
    local transport = mock.create_transport_stub({
        { status_code = 200, body = '{"libraries":[{"id":"lib1","name":"Audiobooks"}]}' },
    })
    api.init("https://abs.example.com", "tok", transport)

    local ok, data = api.getLibraries()
    mock.assert_equals(ok, true, "getLibraries should succeed")
    mock.assert_equals(#data.libraries, 1, "should have 1 library")
    mock.assert_equals(data.libraries[1].id, "lib1", "library id should be lib1")
    mock.assert_equals(data.libraries[1].name, "Audiobooks", "library name should be Audiobooks")
end)

run_test("getLibraries sends correct URL and headers", function()
    local transport = mock.create_transport_stub({
        { status_code = 200, body = '{"libraries":[]}' },
    })
    api.init("https://abs.example.com", "tok123", transport)

    api.getLibraries()
    local log = transport._call_log[1]
    mock.assert_equals(log.url, "https://abs.example.com/api/libraries", "should call correct URL")
    mock.assert_equals(log.method, "GET", "should use GET")
    mock.assert_equals(log.headers["Authorization"], "Bearer tok123", "should send Bearer token")
end)

run_test("getLibraryItems returns items with query params", function()
    local transport = mock.create_transport_stub({
        { status_code = 200, body = '{"results":[{"id":"item1"}],"total":1}' },
    })
    api.init("https://abs.example.com", "tok", transport)

    local ok, data = api.getLibraryItems("lib1", { limit = 10, page = 2, sort = "title" })
    mock.assert_equals(ok, true, "getLibraryItems should succeed")
    mock.assert_equals(#data.results, 1, "should have 1 result")
    mock.assert_equals(data.total, 1, "total should be 1")

    local log = transport._call_log[1]
    mock.assert_equals(log.url:match("/api/libraries/lib1/items"), "/api/libraries/lib1/items", "should include library ID in path")
    mock.assert_equals(log.url:match("limit=10"), "limit=10", "should include limit param")
    mock.assert_equals(log.url:match("page=2"), "page=2", "should include page param")
    mock.assert_equals(log.url:match("sort=title"), "sort=title", "should include sort param")
end)

run_test("getItemDetails returns item data", function()
    local transport = mock.create_transport_stub({
        { status_code = 200, body = '{"id":"item1","media":{"metadata":{"title":"Test Book"}}}' },
    })
    api.init("https://abs.example.com", "tok", transport)

    local ok, data = api.getItemDetails("item1")
    mock.assert_equals(ok, true, "getItemDetails should succeed")
    mock.assert_equals(data.id, "item1", "item id should be item1")
    mock.assert_equals(data.media.metadata.title, "Test Book", "should parse nested data")

    local log = transport._call_log[1]
    mock.assert_equals(log.url, "https://abs.example.com/api/items/item1?expanded=1", "should call expanded endpoint")
end)

run_test("downloadFile returns status code on success", function()
    local chunks = {}
    local sink = function(chunk)
        if chunk then table.insert(chunks, chunk) end
        return true
    end
    local transport = mock.create_transport_stub({
        { status_code = 200, body = "binary-audio-data" },
    })
    api.init("https://abs.example.com", "tok", transport)

    local ok, result = api.downloadFile("item1", "ino123", sink)
    mock.assert_equals(ok, true, "downloadFile should succeed")
    mock.assert_equals(result, 200, "should return status code 200")

    local log = transport._call_log[1]
    mock.assert_equals(log.url:match("/api/items/item1/file/ino123"), "/api/items/item1/file/ino123", "should include item and inode in path")
    -- downloadFile uses token in URL, not Bearer header
    mock.assert_equals(log.url:match("token=tok"), "token=tok", "should include token in URL query")
end)

run_test("downloadFile merges extra_headers into request", function()
    local chunks = {}
    local sink = function(chunk)
        if chunk then table.insert(chunks, chunk) end
        return true
    end
    local transport = mock.create_transport_stub({
        { status_code = 200, body = "binary-data" },
    })
    api.init("https://abs.example.com", "tok", transport)

    local ok, result = api.downloadFile("item1", "ino123", sink, {
        ["Range"] = "bytes=5000-",
    })
    mock.assert_equals(ok, true, "downloadFile should succeed")

    local log = transport._call_log[1]
    mock.assert_equals(log.headers["Accept"], "*/*", "should keep default Accept header")
    mock.assert_equals(log.headers["Range"], "bytes=5000-", "should include Range header")
end)

run_test("getProgress returns progress data", function()
    local transport = mock.create_transport_stub({
        { status_code = 200, body = '{"currentTime":50,"duration":100}' },
    })
    api.init("https://abs.example.com", "tok", transport)

    local ok, data = api.getProgress("item1")
    mock.assert_equals(ok, true, "getProgress should succeed")
    mock.assert_equals(data.currentTime, 50, "currentTime should be 50")
    mock.assert_equals(data.duration, 100, "duration should be 100")
end)

run_test("getProgress returns (true, nil) on 404 — expected state", function()
    local transport = mock.create_transport_stub({
        { status_code = 404 },
    })
    api.init("https://abs.example.com", "tok", transport)

    local ok, data = api.getProgress("item1")
    mock.assert_equals(ok, true, "getProgress should return ok=true on 404")
    mock.assert_equals(data, nil, "getProgress should return nil data on 404")
end)

run_test("updateProgress sends PATCH and returns success", function()
    local transport = mock.create_transport_stub({
        { status_code = 200, body = '{"success":true}' },
    })
    api.init("https://abs.example.com", "tok", transport)

    local body = { currentTime = 42.5, duration = 100, progress = 0.425, isFinished = false }
    local ok, data = api.updateProgress("item1", body)
    mock.assert_equals(ok, true, "updateProgress should succeed")
    mock.assert_equals(data.success, true, "should return success")

    local log = transport._call_log[1]
    mock.assert_equals(log.method, "PATCH", "should use PATCH method")
    mock.assert_equals(log.url, "https://abs.example.com/api/me/progress/item1", "should call correct URL")
end)

run_test("getItemsInProgress returns items", function()
    local transport = mock.create_transport_stub({
        { status_code = 200, body = '{"libraryItems":[{"id":"item1"},{"id":"item2"}]}' },
    })
    api.init("https://abs.example.com", "tok", transport)

    local ok, data = api.getItemsInProgress({ limit = 5 })
    mock.assert_equals(ok, true, "getItemsInProgress should succeed")
    mock.assert_equals(#data.libraryItems, 2, "should have 2 items")

    local log = transport._call_log[1]
    mock.assert_equals(log.url:match("limit=5"), "limit=5", "should include limit param")
end)

run_test("getCover returns status code on success", function()
    local chunks = {}
    local sink = function(chunk)
        if chunk then table.insert(chunks, chunk) end
        return true
    end
    local transport = mock.create_transport_stub({
        { status_code = 200, body = "jpeg-data-here" },
    })
    api.init("https://abs.example.com", "tok", transport)

    local ok, result = api.getCover("item1", sink)
    mock.assert_equals(ok, true, "getCover should succeed")
    mock.assert_equals(result, 200, "should return status code 200")

    local log = transport._call_log[1]
    mock.assert_equals(log.url, "https://abs.example.com/api/items/item1/cover", "should call correct URL")
end)

-- ============================================================
-- Error handling tests
-- ============================================================

run_test("getLibraries returns auth error on 401", function()
    local transport = mock.create_transport_stub({
        { status_code = 401 },
    })
    api.init("https://abs.example.com", "bad-token", transport)

    local ok, err = api.getLibraries()
    mock.assert_equals(ok, false, "should fail on 401")
    mock.assert_equals(err.type, "auth", "error type should be auth")
    mock.assert_equals(err.status_code, 401, "status_code should be 401")
end)

run_test("getLibraries returns not_found error on 404", function()
    local transport = mock.create_transport_stub({
        { status_code = 404 },
    })
    api.init("https://abs.example.com", "tok", transport)

    local ok, err = api.getLibraries()
    mock.assert_equals(ok, false, "should fail on 404")
    mock.assert_equals(err.type, "not_found", "error type should be not_found")
end)

run_test("getLibraries returns server error on 500", function()
    local transport = mock.create_transport_stub({
        { status_code = 500 },
    })
    api.init("https://abs.example.com", "tok", transport)

    local ok, err = api.getLibraries()
    mock.assert_equals(ok, false, "should fail on 500")
    mock.assert_equals(err.type, "server", "error type should be server")
end)

run_test("getLibraries returns client error on 400", function()
    local transport = mock.create_transport_stub({
        { status_code = 400 },
    })
    api.init("https://abs.example.com", "tok", transport)

    local ok, err = api.getLibraries()
    mock.assert_equals(ok, false, "should fail on 400")
    mock.assert_equals(err.type, "client", "error type should be client")
end)

run_test("getLibraries returns network error on connection failure", function()
    local transport = mock.create_transport_stub({
        { error = "connection refused" },
    })
    api.init("https://abs.example.com", "tok", transport)

    local ok, err = api.getLibraries()
    mock.assert_equals(ok, false, "should fail on connection error")
    mock.assert_equals(err.type, "network", "error type should be network")
end)

-- ============================================================
-- Retry behavior test
-- ============================================================

run_test("retries on 500 and succeeds on third attempt", function()
    local transport = mock.create_transport_stub({
        { status_code = 500 },
        { status_code = 500 },
        { status_code = 200, body = '{"libraries":[]}' },
    })
    api.init("https://abs.example.com", "tok", transport)

    with_fast_time(function()
        local ok, data = api.getLibraries()
        mock.assert_equals(ok, true, "should succeed after retries")
        mock.assert_equals(#data.libraries, 0, "should return empty libraries")
    end)

    mock.assert_equals(#transport._call_log, 3, "should have made 3 requests")
end)

run_test("does not retry on 401 (non-retryable)", function()
    local transport = mock.create_transport_stub({
        { status_code = 401 },
        { status_code = 200, body = '{"libraries":[]}' },
    })
    api.init("https://abs.example.com", "tok", transport)

    local ok, err = api.getLibraries()
    mock.assert_equals(ok, false, "should fail on 401")
    mock.assert_equals(err.type, "auth", "error type should be auth")
    mock.assert_equals(#transport._call_log, 1, "should only make 1 request (no retry)")
end)

-- ============================================================
-- JSON parsing edge cases
-- ============================================================

run_test("empty response body returns parse error", function()
    local transport = mock.create_transport_stub({
        { status_code = 200, body = "" },
    })
    api.init("https://abs.example.com", "tok", transport)

    local ok, err = api.getLibraries()
    mock.assert_equals(ok, false, "should fail on empty body")
    mock.assert_equals(err.type, "parse", "error type should be parse")
    mock.assert_equals(err.message, "Empty response from server", "should have empty response message")
end)

run_test("malformed JSON returns parse error", function()
    local transport = mock.create_transport_stub({
        { status_code = 200, body = "this is not json" },
    })
    api.init("https://abs.example.com", "tok", transport)

    local ok, err = api.getLibraries()
    mock.assert_equals(ok, false, "should fail on malformed JSON")
    mock.assert_equals(err.type, "parse", "error type should be parse")
end)

run_test("no response body (nil sink) returns parse error", function()
    local transport = mock.create_transport_stub({
        { status_code = 200 }, -- no body written to sink
    })
    api.init("https://abs.example.com", "tok", transport)

    local ok, err = api.getLibraries()
    mock.assert_equals(ok, false, "should fail when no body")
    mock.assert_equals(err.type, "parse", "error type should be parse")
end)

-- ============================================================
-- Production callers unchanged — api.init(url, token) still works
-- ============================================================

run_test("api.init with two args (production signature) configures client", function()
    -- This test verifies backward compatibility: api.init(url, token)
    -- works without transport parameter. The transport defaults to
    -- a socket.http wrapper (which won't work in test env, but
    -- is_configured() should still return true).
    api.init("https://abs.example.com", "test-token")
    mock.assert_equals(api.is_configured(), true, "should be configured with 2 args")
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
