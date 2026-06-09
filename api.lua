-- API client for absaudio.koplugin
-- Wraps all 9 ABS endpoints with Bearer token auth, retry-with-backoff
-- via socketutil, timeout management, and pcall wrapping on every call.
--
-- Public API:
--   api.init(server_url, token)     -- configure client
--   api.getLibraries()              -- GET /api/libraries
--   api.getLibraryItems(lib_id, opts) -- GET /api/libraries/:id/items
--   api.getItemDetails(item_id)     -- GET /api/items/:id?expanded=1
--   api.downloadFile(item_id, ino, sink) -- GET /api/items/:id/file/:ino
--   api.getProgress(item_id)        -- GET /api/me/progress/:id
--   api.updateProgress(item_id, body) -- PATCH /api/me/progress/:id
--   api.getItemsInProgress(opts)    -- GET /api/me/items-in-progress
--   api.getCover(item_id, sink)     -- GET /api/items/:id/cover
--
-- All functions return: ok, result_or_error
--   ok = true, result = parsed data (on success)
--   ok = false, error_info = {type, status_code, message} (on failure)

local abs_logger = require("abs_logger")

local api = {}

-- Configuration
local server_url = nil
local auth_token = nil
local transport = nil  -- injectable HTTP transport (nil until init)

-- Retry settings
local MAX_RETRIES = 3
local INITIAL_DELAY = 1   -- seconds
local BACKOFF_MULTIPLIER = 2

-- Request timeout settings (seconds)
local CONNECT_TIMEOUT = 10
local REQUEST_TIMEOUT = 15
local DOWNLOAD_TIMEOUT = 30

-- Try to load network modules (may not be available in test env)
local socket_http_ok, socket_http = pcall(require, "socket.http")
local ltn12_ok, ltn12 = pcall(require, "ltn12")
local socketutil_ok, socketutil = pcall(require, "socketutil")
local json_ok, json = pcall(require, "json")

--- Configure the API client with server URL and auth token
-- @param url string  ABS server base URL (no trailing slash)
-- @param token string  API token
-- @param custom_transport table|nil  optional transport adapter with .request(req)
function api.init(url, token, custom_transport)
    server_url = url
    auth_token = token
    if custom_transport then
        transport = custom_transport
    else
        -- Default: wrap socket.http for production use
        transport = {
            request = function(req)
                return socket_http.request(req)
            end
        }
    end
    abs_logger.verbose("API client configured for " .. tostring(server_url))
end

--- Exponential backoff delay
-- @param attempt number  retry attempt number (0-based)
-- @return number  delay in seconds
local function backoff_delay(attempt)
    return INITIAL_DELAY * (BACKOFF_MULTIPLIER ^ attempt)
end

--- Classify an HTTP status code into an error type
-- @param status_code number
-- @return string  error type: "auth", "not_found", "server", "client", "unknown"
local function classify_http_error(status_code)
    if status_code == 401 or status_code == 403 then
        return "auth"
    elseif status_code == 404 then
        return "not_found"
    elseif status_code >= 500 then
        return "server"
    elseif status_code >= 400 then
        return "client"
    end
    return "unknown"
end

--- Get a user-facing message for an HTTP error
-- @param status_code number
-- @return string  user-facing error message
function api.get_http_error_message(status_code)
    if status_code == 401 or status_code == 403 then
        return "Check your server URL and API token in Settings."
    elseif status_code == 404 then
        return "Item not found on server. It may have been removed."
    elseif status_code >= 500 then
        return "Server error. Please try again later."
    else
        return "Unexpected response from server (HTTP " .. tostring(status_code) .. ")."
    end
end

--- Should this HTTP status code trigger a retry?
-- @param status_code number
-- @return boolean
local function should_retry(status_code)
    return status_code >= 500 or status_code == 429
end

--- Make an HTTP request with retry-with-backoff
-- @param request table  socket.http request table
-- @param retry_on_5xx boolean  whether to retry on server errors
-- @return boolean ok
-- @return number|string  status_code on success, error message on failure
local function request_with_retry(request, retry_on_5xx)
    if not transport then
        return false, {type = "network", message = "API client not initialized — call api.init() first"}
    end

    local last_error
    local max_attempts = retry_on_5xx and (MAX_RETRIES + 1) or 1

    for attempt = 1, max_attempts do
        abs_logger.verbose("Request attempt " .. attempt .. "/" .. max_attempts .. " " .. (request.method or "GET") .. " " .. request.url)

        local ok, status_code = pcall(function()
            local _, code = transport.request(request)
            return code
        end)

        if ok then
            if type(status_code) == "number" then
                if status_code >= 200 and status_code < 300 then
                    return true, status_code
                elseif retry_on_5xx and should_retry(status_code) and attempt < max_attempts then
                    local delay = backoff_delay(attempt - 1)
                    abs_logger.info("HTTP " .. status_code .. " — retrying in " .. delay .. "s (attempt " .. attempt .. "/" .. MAX_RETRIES .. ")")
                    -- Busy-wait approximation for backoff (no socket.select in all envs)
                    local t0 = os.time()
                    while os.time() - t0 < delay do end -- luacheck: ignore
                    last_error = {type = classify_http_error(status_code), status_code = status_code, message = api.get_http_error_message(status_code)}
                else
                    return false, {type = classify_http_error(status_code), status_code = status_code, message = api.get_http_error_message(status_code)}
                end
            else
                -- socket.http returns a string error (e.g. "host not found")
                if attempt < max_attempts then
                    local delay = backoff_delay(attempt - 1)
                    abs_logger.info("Connection error: " .. tostring(status_code) .. " — retrying in " .. delay .. "s")
                    local t0 = os.time()
                    while os.time() - t0 < delay do end -- luacheck: ignore
                    last_error = {type = "network", message = tostring(status_code)}
                else
                    return false, {type = "network", message = tostring(status_code)}
                end
            end
        else
            -- pcall caught an exception (e.g. network unreachable)
            if attempt < max_attempts then
                local delay = backoff_delay(attempt - 1)
                abs_logger.info("Request failed: " .. tostring(status_code) .. " — retrying in " .. delay .. "s")
                local t0 = os.time()
                while os.time() - t0 < delay do end -- luacheck: ignore
                last_error = {type = "network", message = tostring(status_code)}
            else
                return false, {type = "network", message = tostring(status_code)}
            end
        end
    end

    return false, last_error
end

--- Set socketutil timeouts (if available)
-- @param connect_timeout number|nil  override connect timeout
-- @param request_timeout number|nil  override request timeout
local function set_timeout(connect_timeout, request_timeout)
    if socketutil_ok and socketutil and socketutil.set_timeout then
        socketutil:set_timeout(connect_timeout or CONNECT_TIMEOUT, request_timeout or REQUEST_TIMEOUT)
    end
end

--- Reset socketutil timeouts
local function reset_timeout()
    if socketutil_ok and socketutil and socketutil.reset_timeout then
        socketutil:reset_timeout()
    end
end

--- Build common request headers
-- @return table  headers table with Authorization and Accept
local function build_headers()
    return {
        ["Authorization"] = "Bearer " .. (auth_token or ""),
        ["Accept"] = "application/json",
    }
end

--- Parse JSON response body
-- @param response_body table  array of strings from ltn12 sink
-- @return boolean ok
-- @return table|string  parsed data or error info
local function parse_json_response(response_body)
    if not json_ok then
        return false, {type = "parse", message = "JSON module not available"}
    end

    local raw = table.concat(response_body)
    if raw == nil or raw == "" then
        return false, {type = "parse", message = "Empty response from server"}
    end

    local data, _, err = json.decode(raw)
    if err then
        abs_logger.warn("JSON parse error: " .. tostring(err))
        return false, {type = "parse", message = "Unexpected response from server"}
    end

    return true, data
end

--- GET /api/libraries
-- Lists all libraries accessible to the authenticated user.
-- @return boolean ok
-- @return table|error  {libraries = [...]} on success
function api.getLibraries()
    abs_logger.verbose("GET /api/libraries")

    local response_body = {}
    set_timeout()

    local request = {
        url = server_url .. "/api/libraries",
        method = "GET",
        headers = build_headers(),
        sink = ltn12_ok and ltn12.sink.table(response_body) or nil,
    }

    local ok, result = request_with_retry(request, true)
    reset_timeout()

    if not ok then return false, result end

    local json_ok, data = parse_json_response(response_body)
    if not json_ok then return false, data end

    abs_logger.info("Retrieved " .. #(data.libraries or {}) .. " libraries")
    return true, data
end

--- GET /api/libraries/:id/items
-- Lists all items in a library. Fetches all items (limit=0) for client-side
-- pagination and sorting as per PRD.
-- @param library_id string  ABS library ID
-- @param opts table|nil  optional {limit, page, sort, desc, search, filter}
-- @return boolean ok
-- @return table|error  {results = [...], total = N} on success
function api.getLibraryItems(library_id, opts)
    opts = opts or {}
    local query_parts = {}

    -- Fetch all items for client-side pagination (PRD: fetch-all, paginate locally)
    table.insert(query_parts, "limit=" .. tostring(opts.limit or 0))
    if opts.page then table.insert(query_parts, "page=" .. tostring(opts.page)) end
    if opts.sort then table.insert(query_parts, "sort=" .. tostring(opts.sort)) end
    if opts.desc then table.insert(query_parts, "desc=1") end
    if opts.search then table.insert(query_parts, "search=" .. tostring(opts.search)) end
    if opts.filter then table.insert(query_parts, "filter=" .. tostring(opts.filter)) end

    local query_string = "?" .. table.concat(query_parts, "&")
    local path = "/api/libraries/" .. library_id .. "/items" .. query_string

    abs_logger.verbose("GET " .. path)

    local response_body = {}
    set_timeout()

    local request = {
        url = server_url .. path,
        method = "GET",
        headers = build_headers(),
        sink = ltn12_ok and ltn12.sink.table(response_body) or nil,
    }

    local ok, result = request_with_retry(request, true)
    reset_timeout()

    if not ok then return false, result end

    local json_ok, data = parse_json_response(response_body)
    if not json_ok then return false, data end

    abs_logger.info("Retrieved " .. #(data.results or {}) .. " items from library " .. library_id)
    return true, data
end

--- GET /api/items/:id?expanded=1
-- Gets item details including audio files, chapters, and metadata.
-- @param item_id string  ABS item ID
-- @return boolean ok
-- @return table|error  item with media, audioFiles, chapters on success
function api.getItemDetails(item_id)
    abs_logger.verbose("GET /api/items/" .. item_id .. "?expanded=1")

    local response_body = {}
    set_timeout()

    local request = {
        url = server_url .. "/api/items/" .. item_id .. "?expanded=1",
        method = "GET",
        headers = build_headers(),
        sink = ltn12_ok and ltn12.sink.table(response_body) or nil,
    }

    local ok, result = request_with_retry(request, true)
    reset_timeout()

    if not ok then return false, result end

    local json_ok, data = parse_json_response(response_body)
    if not json_ok then return false, data end

    abs_logger.info("Retrieved item details for " .. item_id)
    return true, data
end

--- GET /api/items/:id/file/:ino
-- Downloads a specific file (audio or ebook) as a binary stream.
-- Uses longer timeout for large file downloads.
-- @param item_id string  ABS item ID
-- @param ino string  file inode number
-- @param sink function  ltn12 sink to receive data
-- @param extra_headers table|nil  optional extra headers (e.g. Range for resume)
-- @return boolean ok
-- @return number|error  status code or error info
function api.downloadFile(item_id, ino, sink, extra_headers)
    local path = "/api/items/" .. item_id .. "/file/" .. ino
    abs_logger.verbose("GET " .. path)

    set_timeout(CONNECT_TIMEOUT, DOWNLOAD_TIMEOUT)

    local headers = {
        ["Accept"] = "*/*",
    }
    if extra_headers then
        for k, v in pairs(extra_headers) do
            headers[k] = v
        end
    end

    local request = {
        url = server_url .. path .. "?token=" .. (auth_token or ""),
        method = "GET",
        headers = headers,
        sink = sink,
    }

    local ok, result = request_with_retry(request, true)
    reset_timeout()

    if not ok then return false, result end
    abs_logger.info("Downloaded file " .. ino .. " from item " .. item_id)
    return true, result
end

--- GET /api/me/progress/:id
-- Gets playback progress for an item. Returns nil gracefully on 404
-- (no progress yet — expected state).
-- @param item_id string  ABS item ID
-- @return boolean ok
-- @return table|nil|error  progress object, nil (no progress), or error
function api.getProgress(item_id)
    abs_logger.verbose("GET /api/me/progress/" .. item_id)

    local response_body = {}
    set_timeout()

    local request = {
        url = server_url .. "/api/me/progress/" .. item_id,
        method = "GET",
        headers = build_headers(),
        sink = ltn12_ok and ltn12.sink.table(response_body) or nil,
    }

    local ok, result = request_with_retry(request, false)
    reset_timeout()

    if not ok then
        -- 404 on progress is expected (no progress yet) — return nil, not error
        if type(result) == "table" and result.status_code == 404 then
            abs_logger.verbose("No progress found for " .. item_id .. " (expected for new books)")
            return true, nil
        end
        return false, result
    end

    local json_ok, data = parse_json_response(response_body)
    if not json_ok then return false, data end

    return true, data
end

--- PATCH /api/me/progress/:id
-- Updates playback progress for an item.
-- @param item_id string  ABS item ID
-- @param body table  {currentTime, duration, progress, isFinished}
-- @return boolean ok
-- @return table|error  success info or error
function api.updateProgress(item_id, body)
    abs_logger.verbose("PATCH /api/me/progress/" .. item_id)

    if not json_ok then
        return false, {type = "parse", message = "JSON module not available"}
    end

    local request_body = json.encode(body)

    local response_body = {}
    set_timeout()

    local request = {
        url = server_url .. "/api/me/progress/" .. item_id,
        method = "PATCH",
        headers = {
            ["Authorization"] = "Bearer " .. (auth_token or ""),
            ["Accept"] = "application/json",
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#request_body),
        },
        source = ltn12_ok and ltn12.source.string(request_body) or nil,
        sink = ltn12_ok and ltn12.sink.table(response_body) or nil,
    }

    local ok, result = request_with_retry(request, true)
    reset_timeout()

    if not ok then return false, result end

    abs_logger.info("Updated progress for " .. item_id .. " (currentTime=" .. tostring(body.currentTime) .. ")")
    return true, {success = true}
end

--- GET /api/me/items-in-progress
-- Gets all items that have playback progress.
-- @param opts table|nil  optional {limit}
-- @return boolean ok
-- @return table|error  {libraryItems = [...]} on success
function api.getItemsInProgress(opts)
    opts = opts or {}
    local query = ""
    if opts.limit then query = "?limit=" .. tostring(opts.limit) end

    abs_logger.verbose("GET /api/me/items-in-progress" .. query)

    local response_body = {}
    set_timeout()

    local request = {
        url = server_url .. "/api/me/items-in-progress" .. query,
        method = "GET",
        headers = build_headers(),
        sink = ltn12_ok and ltn12.sink.table(response_body) or nil,
    }

    local ok, result = request_with_retry(request, true)
    reset_timeout()

    if not ok then return false, result end

    local json_ok, data = parse_json_response(response_body)
    if not json_ok then return false, data end

    abs_logger.info("Retrieved " .. #(data.libraryItems or {}) .. " items in progress")
    return true, data
end

--- GET /api/items/:id/cover
-- Fetches cover image for an item as a binary stream.
-- @param item_id string  ABS item ID
-- @param sink function  ltn12 sink to receive image data
-- @return boolean ok
-- @return number|error  status code or error info
function api.getCover(item_id, sink)
    abs_logger.verbose("GET /api/items/" .. item_id .. "/cover")

    set_timeout(CONNECT_TIMEOUT, DOWNLOAD_TIMEOUT)

    local request = {
        url = server_url .. "/api/items/" .. item_id .. "/cover",
        method = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. (auth_token or ""),
            ["Accept"] = "image/*,*/*",
        },
        sink = sink,
    }

    local ok, result = request_with_retry(request, false)
    reset_timeout()

    if not ok then
        -- Cover fetch failure should never block UI — log and return gracefully
        abs_logger.warn("Cover fetch failed for " .. item_id .. ": " .. tostring(result.message or "unknown"))
        return false, result
    end

    return true, result
end

--- Check if the API client is configured
-- @return boolean
function api.is_configured()
    return server_url ~= nil and server_url ~= ""
        and auth_token ~= nil and auth_token ~= ""
end

return api
