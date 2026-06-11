-- test_chunked_http.lua — Tests for the chunked_http module
--
-- Run: lua spec/test_chunked_http.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

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
}

local mock = require("spec/test_helper")
local chunked_http = dofile("absaudio/chunked_http.lua")

local passed = 0
local failed = 0

local function run_test(name, func)
    local ok, err = pcall(func)
    if ok then
        passed = passed + 1
        print("  ✓ " .. name)
    else
        failed = failed + 1
        print("  ✗ " .. name)
        print("    " .. tostring(err))
    end
end

------------------------------------------------------------------------
-- parse_url tests
------------------------------------------------------------------------
-- parse_url is local, but we can test it indirectly through download
-- or by requiring it. Since it's local, we test via the download
-- function's error messages.

------------------------------------------------------------------------
-- URL validation via download (parse_url is local)
------------------------------------------------------------------------
run_test("download returns error when socket unavailable", function()
    -- Reset module state to no socket
    chunked_http.init({})
    local ok, err = chunked_http.download("https://example.com/file")
    mock.assert_equals(ok, false, "should fail")
    mock.assert_equals(err:find("not initialized") ~= nil or err:find("socket") ~= nil, true,
        "error should mention initialization or socket: " .. tostring(err))
end)

------------------------------------------------------------------------
-- init + download with mock socket
------------------------------------------------------------------------
run_test("download with mock socket — content-length body", function()
    local chunks_received = {}
    local connect_called = false
    local send_data = nil
    local closed = false
    local state = 0

    local mock_sock = {
        settimeout = function(self, t) end,
        connect = function(self, host, port)
            connect_called = true
            mock.assert_equals(host, "example.com")
            mock.assert_equals(port, 443)
        end,
        send = function(self, data)
            send_data = data
        end,
        receive = function(self, spec)
            state = state + 1
            if state == 1 then return "HTTP/1.1 200 OK" end
            if state == 2 then return "Content-Length: 12" end
            if state == 3 then return "" end  -- blank line ends headers
            if state == 4 then return "Hello World!" end  -- 12 bytes
            return nil, "closed"
        end,
        close = function(self)
            closed = true
        end,
    }

    local mock_ssl = {
        wrap = function(sock, params)
            mock.assert_equals(params.mode, "client")
            return {
                sni = function(self, host) end,
                dohandshake = function(self) end,
                send = function(self, data) end,
                receive = function(self, spec)
                    return mock_sock:receive(spec)
                end,
                close = function(self)
                    closed = true
                end,
            }
        end,
    }

    chunked_http.init({
        socket = {
            tcp = function()
                return mock_sock
            end,
        },
        ssl = mock_ssl,
        logger = {
            verbose = function() end,
            info = function() end,
            warn = function() end,
        },
    })

    -- Run download inside a coroutine so yield works
    local co = coroutine.create(function()
        return chunked_http.download(
            "https://example.com/path/to/file",
            nil,
            function(chunk)
                table.insert(chunks_received, chunk)
            end
        )
    end)

    local ok, result1, result2
    while true do
        ok, result1, result2 = coroutine.resume(co)
        if not ok or coroutine.status(co) == "dead" then
            break
        end
    end

    mock.assert_equals(result1, true, "download should succeed")
    mock.assert_equals(result2, 200, "status should be 200")
    mock.assert_equals(#chunks_received, 1, "should have 1 chunk")
    mock.assert_equals(chunks_received[1], "Hello World!", "chunk content should match")
end)

run_test("download with HTTP (no TLS)", function()
    local chunks_received = {}
    local connected_port = nil

    local mock_sock = {
        settimeout = function() end,
        connect = function(self, host, port)
            connected_port = port
        end,
        send = function() end,
        receive = function(self, spec)
            if not self._step then
                self._step = 1
            end
            if self._step == 1 then
                self._step = 2
                return "HTTP/1.1 200 OK"
            end
            if self._step == 2 then
                self._step = 3
                return "Content-Length: 5"
            end
            if self._step == 3 then
                self._step = 4
                return ""
            end
            if self._step == 4 then
                self._step = 5
                return "hello"
            end
            return nil, "closed"
        end,
        close = function() end,
    }

    chunked_http.init({
        socket = {
            tcp = function() return mock_sock end,
        },
        ssl = nil,  -- no SSL for HTTP
        logger = { verbose = function() end, info = function() end, warn = function() end },
    })

    local co = coroutine.create(function()
        return chunked_http.download(
            "http://example.com/file.txt",
            nil,
            function(chunk) table.insert(chunks_received, chunk) end
        )
    end)

    local ok, r1, r2
    while true do
        ok, r1, r2 = coroutine.resume(co)
        if not ok or coroutine.status(co) == "dead" then break end
    end

    mock.assert_equals(r1, true, "download should succeed")
    mock.assert_equals(r2, 200, "status should be 200")
    mock.assert_equals(connected_port, 80, "should connect to port 80")
    mock.assert_equals(chunks_received[1], "hello", "content should match")
end)

run_test("download yields between chunks for large content-length", function()
    local pump_count = 0

    local mock_sock = {
        settimeout = function() end,
        connect = function() end,
        send = function() end,
        receive = function(self, spec)
            if not self._step then self._step = 0 end
            self._step = self._step + 1

            if self._step == 1 then return "HTTP/1.1 200 OK" end
            if self._step == 2 then return "Content-Length: 10" end
            if self._step == 3 then return "" end
            -- Body: two 5-byte reads
            if self._step == 4 then return "12345" end
            if self._step == 5 then return "67890" end
            return nil, "closed"
        end,
        close = function() end,
    }

    chunked_http.init({
        socket = { tcp = function() return mock_sock end },
        ssl = nil,
        logger = { verbose = function() end, info = function() end, warn = function() end },
    })

    local co = coroutine.create(function()
        return chunked_http.download(
            "http://example.com/bigfile.bin",
            nil,
            function(chunk) end,
            5  -- 5-byte chunks
        )
    end)

    while true do
        local ok = coroutine.resume(co)
        pump_count = pump_count + 1
        if not ok or coroutine.status(co) == "dead" then break end
        if pump_count > 10 then break end  -- safety
    end

    mock.assert_equals(pump_count >= 2, true,
        "should yield between chunks (pumps: " .. pump_count .. ")")
end)

run_test("download handles 404 error", function()
    local mock_sock = {
        settimeout = function() end,
        connect = function() end,
        send = function() end,
        receive = function(self, spec)
            if not self._step then self._step = 0 end
            self._step = self._step + 1
            if self._step == 1 then return "HTTP/1.1 404 Not Found" end
            if self._step == 2 then return "Content-Length: 0" end
            if self._step == 3 then return "" end
            return nil, "closed"
        end,
        close = function() end,
    }

    chunked_http.init({
        socket = { tcp = function() return mock_sock end },
        ssl = nil,
        logger = { verbose = function() end, info = function() end, warn = function() end },
    })

    local ok, result = chunked_http.download(
        "http://example.com/missing",
        nil,
        function() end
    )

    mock.assert_equals(ok, false, "should fail for 404")
    mock.assert_equals(result, 404, "should return 404 status code")
end)

run_test("download handles connection failure", function()
    chunked_http.init({
        socket = {
            tcp = function()
                return {
                    settimeout = function() end,
                    connect = function(self)
                        error("connection refused")
                    end,
                    close = function() end,
                }
            end,
        },
        ssl = nil,
        logger = { verbose = function() end, info = function() end, warn = function() end },
    })

    local ok, err = chunked_http.download(
        "http://example.com/file",
        nil,
        function() end
    )

    mock.assert_equals(ok, false, "should fail on connection error")
    mock.assert_equals(err:find("connect") ~= nil, true,
        "error should mention connect: " .. tostring(err))
end)

------------------------------------------------------------------------
-- Summary
------------------------------------------------------------------------
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
