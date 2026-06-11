-- Shared filesystem helpers for absaudio.koplugin
-- Provides mkdir_p, get_file_size, delete_file, delete_dir
-- to eliminate copy-pasted filesystem operations across modules.
--
-- Public API:
--   fs_helpers.mkdir_p(path)          -- recursive directory creation (like mkdir -p)
--   fs_helpers.get_file_size(path)    -- safe lfs.attributes size lookup
--   fs_helpers.delete_file(path)      -- os.remove wrapper
--   fs_helpers.delete_dir(path)       -- lfs.rmdir wrapper
-- Return convention: boolean (true/false) for delete operations; direct value for get_file_size.

local abs_logger = require("abs_logger")

-- Load lfs (KOReader provides it as global, not always as loadable module)
local lfs = nil
local lfs_ok = false

local _pcall_ok, _pcall_lfs = pcall(require, "lfs")
if _pcall_ok then
    lfs = _pcall_lfs
    lfs_ok = true
elseif type(_G.lfs) == "table" and _G.lfs.mkdir then
    lfs = _G.lfs
    lfs_ok = true
end

local fs_helpers = {}

--- Recursively create directories (like mkdir -p).
-- Creates each missing path component from root to leaf.
-- @param path string  directory path to create
-- @return boolean ok
-- @return string|nil error  error info table on failure, nil on success
function fs_helpers.mkdir_p(path)
    if not path or path == "" then
        return false, { type = "io", message = "mkdir_p: path is nil or empty" }
    end

    if not lfs_ok then
        return false, { type = "io", message = "mkdir_p: lfs not available" }
    end

    -- Split path into components
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part ~= "." then
            table.insert(parts, part)
        end
    end

    -- Build up path incrementally, creating missing components
    local path_so_far = path:match("^/") and "/" or ""
    for _, part in ipairs(parts) do
        path_so_far = path_so_far .. part .. "/"
        local dir = path_so_far:sub(1, -2) -- strip trailing /
        if lfs.attributes(dir, "mode") ~= "directory" then
            local ok, err = lfs.mkdir(dir)
            if not ok then
                abs_logger.warn("Cannot create directory " .. dir .. ": " .. tostring(err))
                return false, { type = "io", message = "Cannot create directory: " .. dir }
            end
        end
    end

    return true, nil
end

--- Get file size safely via lfs.attributes.
-- @param path string  file path
-- @return number|nil  file size in bytes, or nil if unavailable
function fs_helpers.get_file_size(path)
    if not lfs_ok or not path then return nil end
    local attr = lfs.attributes(path)
    return attr and attr.size or nil
end

--- Delete a file via os.remove.
-- @param path string  file path to delete
-- @return boolean  true if removed (or didn't exist), false on error
function fs_helpers.delete_file(path)
    if not path then return false end
    return os.remove(path) ~= nil
end

--- Delete an empty directory via lfs.rmdir.
-- @param path string  directory path to remove
-- @return boolean  true if removed, false on error or if lfs unavailable
function fs_helpers.delete_dir(path)
    if not lfs_ok or not path then return false end
    return lfs.rmdir(path) ~= nil
end

return fs_helpers
