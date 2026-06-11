-- Cover art cache for absaudio.koplugin
-- Fetches cover images from ABS and caches them locally as JPEG files.
-- Provides fast cached lookups for previously fetched covers.
--
-- Public API:
--   cover_cache.init(cache_dir)            -- set cache directory
--   cover_cache.getCoverPath(item_id)      -- get expected file path for a cover
--   cover_cache.hasCachedCover(item_id)    -- check if cover exists on disk
--   cover_cache.fetchAndCache(item_id)     -- fetch from ABS if not cached, store locally
-- Return convention: (boolean, path_or_nil) ok-pattern — true+path on success, false on failure.

local abs_logger = require("abs_logger")

-- Try to load dependencies
local lfs = nil
local lfs_ok = false

-- KOReader provides lfs as a global (built into LuaJIT), not always as a loadable module
local _pcall_ok, _pcall_lfs = pcall(require, "lfs")
if _pcall_ok then
    lfs = _pcall_lfs
    lfs_ok = true
elseif type(_G.lfs) == "table" and _G.lfs.mkdir then
    lfs = _G.lfs
    lfs_ok = true
end
local has_api, api = pcall(require, "api")
local ltn12_ok, ltn12 = pcall(require, "ltn12")
local fs_helpers = pcall(require, "absaudio/fs_helpers")
local has_fs_helpers, fs_helpers = pcall(require, "absaudio/fs_helpers")

local cover_cache = {}

-- Configuration
local cache_dir = nil

--- Initialize the cover cache with a directory path
-- @param dir string  directory to store cached cover images
function cover_cache.isInitialized()
    return cache_dir ~= nil
end

function cover_cache.init(dir)
    cache_dir = dir
    abs_logger.verbose("Cover cache initialized: " .. tostring(dir))
end

--- Get the expected file path for a cover image
-- @param item_id string  ABS item ID
-- @return string  full path to cover image file
function cover_cache.getCoverPath(item_id)
    return cache_dir .. "/" .. item_id .. ".jpg"
end

--- Check if a cover image is already cached on disk
-- @param item_id string  ABS item ID
-- @return boolean
function cover_cache.hasCachedCover(item_id)
    if not lfs_ok then return false end
    local path = cover_cache.getCoverPath(item_id)
    return lfs.attributes(path, "mode") == "file"
end

--- Fetch a cover from ABS and cache it locally.
-- Skips fetch if cover already cached. Creates cache directory if needed.
-- @param item_id string  ABS item ID
-- @return boolean ok
-- @return string|error  cover path on success, error info on failure
function cover_cache.fetchAndCache(item_id)
    -- Check cache first
    if cover_cache.hasCachedCover(item_id) then
        abs_logger.verbose("Cover already cached: " .. item_id)
        return true, cover_cache.getCoverPath(item_id)
    end

    -- Ensure cache directory exists (recursive, like mkdir -p)
    if has_fs_helpers and cache_dir then
        local mkdir_ok, mkdir_err = fs_helpers.mkdir_p(cache_dir)
        if not mkdir_ok then
            return false, mkdir_err
        end
    elseif not cache_dir then
        return false, { type = "io", message = "Cache directory not initialized" }
    end

    -- Fetch from API
    if not has_api then
        return false, {type = "network", message = "API module not available"}
    end

    local cover_path = cover_cache.getCoverPath(item_id)

    -- Fetch cover data using ltn12.sink.table (same pattern as all other
    -- API endpoints). This ensures the complete response is collected
    -- before writing to disk, avoiding truncated files.
    local response_body = {}
    local sink = ltn12_ok and ltn12.sink.table(response_body) or nil

    local ok, result = api.getCover(item_id, sink)

    if not ok then
        abs_logger.warn("Cover fetch failed for " .. item_id)
        return false, result
    end

    -- Write complete response body to file in one shot
    local cover_data = table.concat(response_body)
    if not cover_data or cover_data == "" then
        abs_logger.warn("Empty cover response for " .. item_id)
        return false, {type = "parse", message = "Empty cover response"}
    end

    local file, open_err = io.open(cover_path, "wb")
    if not file then
        abs_logger.warn("Cannot create cover file: " .. tostring(open_err))
        return false, {type = "io", message = "Cannot write cover file"}
    end
    file:write(cover_data)
    file:close()

    abs_logger.info("Cover cached: " .. item_id .. " (" .. #cover_data .. " bytes)")
    return true, cover_path
end

return cover_cache
