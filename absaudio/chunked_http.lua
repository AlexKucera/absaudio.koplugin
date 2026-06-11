-- chunked_http.lua — Yield-safe HTTP download for large files.
--
-- socket.http.request is wrapped in socket.protect(pcall), which
-- creates a C-call boundary that prevents coroutine.yield() from
-- working inside the ltn12 sink.  This module bypasses socket.http
-- entirely, doing raw socket I/O so we can safely yield between
-- chunk reads.
--
-- Public API:
--   chunked_http.download(url, headers, on_chunk, chunk_size)
--     -> true, status_code | false, error_string
-- Return convention: (boolean, status_code|error_string) — ok-pattern for HTTP results.
--
-- Dependencies (injected via module.init or defaults):
--   socket, ssl, url_parser, logger

local chunked_http = {}

------------------------------------------------------------------------
-- Module state
------------------------------------------------------------------------
local socket_mod = nil   -- socket module
local ssl_mod = nil       -- ssl module (LuaSec)
local url_mod = nil       -- socket.url module
local logger = nil        -- abs_logger or stub

------------------------------------------------------------------------
-- Default chunk size for reads (32 KB — balances throughput vs. UI
-- responsiveness; yield happens every read, so smaller = more responsive)
------------------------------------------------------------------------
local DEFAULT_CHUNK_SIZE = 32768

------------------------------------------------------------------------
-- URL parsing (simple, no dependency on socket.url)
------------------------------------------------------------------------
local function parse_url(url_str)
    -- Pattern: scheme://host[:port]/path[?query]
    local scheme, host_port, path_query = url_str:match("^(https?)://([^/]+)(/.*)$")
    if not scheme then
        return nil, "invalid URL: " .. tostring(url_str)
    end

    local host, port
    -- Check for IPv6: [::1]:port
    if host_port:sub(1, 1) == "[" then
        local bracket_end = host_port:find("]")
        if not bracket_end then return nil, "invalid IPv6 host" end
        host = host_port:sub(2, bracket_end - 1)
        local after = host_port:sub(bracket_end + 1)
        if after:sub(1, 1) == ":" then
            port = tonumber(after:sub(2))
        end
    else
        local colon = host_port:find(":")
        if colon then
            host = host_port:sub(1, colon - 1)
            port = tonumber(host_port:sub(colon + 1))
        else
            host = host_port
        end
    end

    if not port then
        port = (scheme == "https") and 443 or 80
    end

    -- Split path and query
    local path, query = path_query:match("^([^?]*)(.*)$")
    if path == "" then path = "/" end

    return {
        scheme = scheme,
        host = host,
        port = port,
        path = path,
        query = query,  -- includes leading "?" or empty
    }
end

------------------------------------------------------------------------
-- Read a line from socket (CRLF-terminated)
------------------------------------------------------------------------
local function recv_line(sock)
    local line, err = sock:receive("*l")
    if err then return nil, err end
    return line
end

------------------------------------------------------------------------
-- Read HTTP response headers into a table
------------------------------------------------------------------------
local function recv_headers(sock)
    local hdrs = {}
    local line, err = recv_line(sock)
    if err then return nil, "reading headers: " .. err end

    -- First line could be blank (shouldn't be, but be safe)
    while line and line ~= "" do
        local name, value = line:match("^([^:]+):%s*(.*)")
        if name then
            name = name:lower()
            -- Handle duplicate headers by appending with comma
            if hdrs[name] then
                hdrs[name] = hdrs[name] .. ", " .. value
            else
                hdrs[name] = value
            end
        end
        line, err = recv_line(sock)
        if err then return nil, "reading headers: " .. err end
    end

    return hdrs
end

------------------------------------------------------------------------
-- Initialize the module with socket/ssl/url dependencies.
-- Call once at startup; safe to call multiple times.
-- @param deps table { socket, ssl, url, logger }
------------------------------------------------------------------------
function chunked_http.init(deps)
    socket_mod = deps.socket
    ssl_mod = deps.ssl
    url_mod = deps.url
    logger = deps.logger or {
        verbose = function() end,
        info = function() end,
        warn = function() end,
    }
end

------------------------------------------------------------------------
-- Auto-initialize with default modules if not explicitly initialized.
-- Safe to call multiple times; does nothing if already initialized.
------------------------------------------------------------------------
local function ensure_initialized()
    if socket_mod then return end

    local ok
    ok, socket_mod = pcall(require, "socket")
    if not ok then socket_mod = nil end

    ok, ssl_mod = pcall(require, "ssl")
    if not ok then ssl_mod = nil end

    ok, url_mod = pcall(require, "socket.url")
    if not ok then url_mod = nil end

    ok, logger = pcall(require, "abs_logger")
    if not ok then
        logger = {
            verbose = function() end,
            info = function() end,
            warn = function() end,
        }
    end
end

------------------------------------------------------------------------
-- Perform a yield-safe HTTP GET download.
--
-- Opens a raw socket (with TLS for HTTPS), sends the request, reads
-- the response, then calls on_chunk(chunk) for each chunk read and
-- yields to the coroutine between reads.  This avoids the C-call
-- boundary problem in socket.http.request.
--
-- @param url string          Full URL (https://host:port/path?query)
-- @param headers table|nil   Additional request headers
-- @param on_chunk function   Called with each data chunk: on_chunk(data)
-- @param chunk_size number   Read size per iteration (default 32KB)
-- @param depth number         Redirect depth (internal; default 0, max 10)
-- @return boolean ok
-- @return number|string      status_code on success, error on failure
------------------------------------------------------------------------
local MAX_REDIRECTS = 10

function chunked_http.download(url, headers, on_chunk, chunk_size, depth)
    if not socket_mod then
        ensure_initialized()
    end
    if not socket_mod then
        return false, "chunked_http not initialized — socket module not available"
    end

    chunk_size = chunk_size or DEFAULT_CHUNK_SIZE
    depth = depth or 0

    -- Parse URL
    local parsed, parse_err = parse_url(url)
    if not parsed then return false, parse_err end

    if logger then logger.verbose("chunked_http GET " .. parsed.host .. parsed.path) end

    -- Build request headers
    local req_headers = {}
    req_headers["Host"] = parsed.host
    req_headers["Connection"] = "close"
    req_headers["Accept"] = "*/*"
    req_headers["User-Agent"] = "KOReader/absaudio"

    if headers then
        for k, v in pairs(headers) do
            req_headers[k] = v
        end
    end

    -- Build request line + headers string
    local request_path = parsed.path .. parsed.query
    local req = "GET " .. request_path .. " HTTP/1.1\r\n"
    for k, v in pairs(req_headers) do
        req = req .. k .. ": " .. v .. "\r\n"
    end
    req = req .. "\r\n"

    -- Create socket and connect
    local sock, connect_err
    local ok, tcp_or_err = pcall(socket_mod.tcp)
    if not ok then
        return false, "socket.tcp() failed: " .. tostring(tcp_or_err)
    end
    sock = tcp_or_err

    -- Set timeout
    if sock.settimeout then
        sock:settimeout(30)
    end

    ok, connect_err = pcall(function() sock:connect(parsed.host, parsed.port) end)
    if not ok then
        pcall(function() sock:close() end)
        return false, "connect failed: " .. tostring(connect_err)
    end

    -- Wrap with TLS for HTTPS
    if parsed.scheme == "https" then
        if not ssl_mod then
            pcall(function() sock:close() end)
            return false, "HTTPS requested but ssl module not available"
        end

        local tls_params = {
            mode = "client",
            protocol = "any",
            options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1" },
            verify = "none",
        }

        ok, connect_err = pcall(function()
            sock = ssl_mod.wrap(sock, tls_params)
            if not sock then error("ssl.wrap returned nil") end
            sock:sni(parsed.host)
            sock:dohandshake()
        end)
        if not ok then
            return false, "TLS handshake failed: " .. tostring(connect_err)
        end
    end

    -- Send request
    ok, connect_err = pcall(function() sock:send(req) end)
    if not ok then
        pcall(function() sock:close() end)
        return false, "send failed: " .. tostring(connect_err)
    end

    -- Read status line
    local status_line
    ok, connect_err = pcall(function() status_line = sock:receive("*l") end)
    if not ok or not status_line then
        pcall(function() sock:close() end)
        return false, "no response: " .. tostring(connect_err or "nil")
    end

    -- Parse status code: "HTTP/1.1 200 OK"
    local status_code = tonumber(status_line:match("HTTP/%d%.%d%s+(%d%d%d)"))
    if not status_code then
        pcall(function() sock:close() end)
        return false, "malformed status line: " .. tostring(status_line)
    end

    -- Read response headers
    local resp_headers
    ok, connect_err = pcall(function() resp_headers = recv_headers(sock) end)
    if not ok or not resp_headers then
        pcall(function() sock:close() end)
        return false, "failed to read headers: " .. tostring(connect_err)
    end

    -- Check for redirect (301, 302, 303, 307)
    if (status_code == 301 or status_code == 302 or status_code == 303 or status_code == 307)
        and resp_headers["location"] then
        pcall(function() sock:close() end)
        local redirect_url = resp_headers["location"]
        -- Handle relative URLs
        if redirect_url:sub(1, 1) == "/" then
            redirect_url = parsed.scheme .. "://" .. parsed.host
                .. (parsed.port ~= 80 and parsed.port ~= 443 and (":" .. parsed.port) or "")
                .. redirect_url
        end
        if depth >= MAX_REDIRECTS then
            pcall(function() sock:close() end)
            return false, "too many redirects (" .. depth .. " hops)"
        end
        return chunked_http.download(redirect_url, headers, on_chunk, chunk_size, depth + 1)
    end

    -- Check for error status
    if status_code >= 400 then
        -- Drain and close
        pcall(function()
            sock:receive("*a")
            sock:close()
        end)
        return false, status_code
    end

    -- Read body in chunks
    local content_length = tonumber(resp_headers["content-length"])
    local transfer_encoding = resp_headers["transfer-encoding"]
    local is_chunked_te = transfer_encoding and transfer_encoding:lower():find("chunked")

    local bytes_remaining = content_length
    local total_read = 0

    if is_chunked_te then
        -- Chunked transfer encoding
        while true do
            local size_line
            ok, connect_err = pcall(function() size_line = sock:receive("*l") end)
            if not ok or not size_line then break end

            local chunk_size_hex = size_line:match("^([^;]*)")
            chunk_size_hex = chunk_size_hex and chunk_size_hex:gsub("%s", "") or "0"
            local chunk_sz = tonumber(chunk_size_hex, 16) or 0

            if chunk_sz == 0 then
                -- Final chunk — read trailing CRLF and done
                pcall(function() sock:receive("*l") end)
                break
            end

            -- Read the chunk data
            local remaining = chunk_sz
            while remaining > 0 do
                local read_size = math.min(remaining, chunk_size)
                local data
                ok, connect_err = pcall(function() data = sock:receive(read_size) end)
                if not ok or not data then
                    pcall(function() sock:close() end)
                    return false, "read error: " .. tostring(connect_err)
                end
                on_chunk(data)
                total_read = total_read + #data
                remaining = remaining - #data
                -- Yield to event loop between reads
                coroutine.yield()
            end
            -- Read trailing CRLF after chunk data
            pcall(function() sock:receive("*l") end)
        end
    elseif content_length then
        -- Content-Length based reading
        while bytes_remaining > 0 do
            local read_size = math.min(bytes_remaining, chunk_size)
            local data
            ok, connect_err = pcall(function() data = sock:receive(read_size) end)
            if not ok or not data then
                pcall(function() sock:close() end)
                return false, "read error at byte " .. total_read .. ": " .. tostring(connect_err)
            end
            on_chunk(data)
            total_read = total_read + #data
            bytes_remaining = bytes_remaining - #data
            -- Yield to event loop between reads
            coroutine.yield()
        end
    else
        -- Read until connection close
        while true do
            local data
            ok, connect_err = pcall(function() data = sock:receive(chunk_size) end)
            if not ok or not data then break end
            on_chunk(data)
            total_read = total_read + #data
            -- Yield to event loop between reads
            coroutine.yield()
        end
    end

    -- Close socket
    pcall(function() sock:close() end)

    return true, status_code
end

return chunked_http
