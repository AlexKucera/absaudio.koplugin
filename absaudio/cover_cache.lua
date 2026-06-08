-- Cover art cache for absaudio.koplugin
-- Fetches cover images from ABS and caches them locally as JPEG files.
-- Provides fast cached lookups for previously fetched covers.
--
-- Public API:
--   cover_cache.init(cache_dir)            -- set cache directory
--   cover_cache.getCoverPath(item_id)      -- get expected file path for a cover
--   cover_cache.hasCachedCover(item_id)    -- check if cover exists on disk
--   cover_cache.fetchAndCache(item_id)     -- fetch from ABS if not cached, store locally

local abs_logger = require("abs_logger")

-- Try to load dependencies
local lfs_ok, lfs = pcall(require, "lfs")
local has_api, api = pcall(require, "api")

local cover_cache = {}

-- Configuration
local cache_dir = nil

--- Initialize the cover cache with a directory path
-- @param dir string  directory to store cached cover images
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

    -- Ensure cache directory exists
    if lfs_ok and cache_dir and not lfs.attributes(cache_dir, "mode") then
        lfs.mkdir(cache_dir)
    end

    -- Fetch from API
    if not has_api then
        return false, {type = "network", message = "API module not available"}
    end

    local cover_path = cover_cache.getCoverPath(item_id)

    -- Open file for writing and stream cover data to it
    local file, open_err = io.open(cover_path, "wb")
    if not file then
        abs_logger.warn("Cannot create cover file: " .. tostring(open_err))
        return false, {type = "io", message = "Cannot write cover file"}
    end

    local function file_sink(data)
        file:write(data)
    end

    local ok, result = api:getCover(item_id, file_sink)
    file:close()

    if not ok then
        -- Clean up failed file
        os.remove(cover_path)
        abs_logger.warn("Cover fetch failed for " .. item_id)
        return false, result
    end

    abs_logger.info("Cover cached: " .. item_id)
    return true, cover_path
end

return cover_cache
