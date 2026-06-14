-- Config manager for absaudio.koplugin
-- Backed by KOReader's LuaSettings. Provides typed access to plugin config
-- with sensible defaults and validation.
--
-- Public API:
--   config.init()              -- initialize config store
--   config.get(key)            -- read a config value
--   config.set(key, value)     -- write a config value (also normalizes)
--   config.is_configured()     -- true when server + token are set
--   config.validate_server_url(url) -- validate/normalize server URL
--   config.get_settings()      -- return underlying LuaSettings (for flush/close)
-- Return convention: direct value (no boolean wrapper) — simple accessor pattern, nil for missing keys.

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")

local config = {}

-- Default values for config fields
local DEFAULTS = {
    preferred_format = "m4b",
    log_level = "verbose",
    playback_speed = 1.0,  -- PRD §Playback Speed: default 1×, local-only (not synced to ABS)
}

-- Internal state
local settings = nil

--- Build the config file path
local function config_path()
    return DataStorage:getSettingsDir() .. "/absaudio.lua"
end

--- Initialize config store (idempotent)
function config.init()
    settings = LuaSettings:open(config_path())
    -- Seed defaults for keys that have them
    for key, default in pairs(DEFAULTS) do
        if settings:readSetting(key) == nil then
            settings:saveSetting(key, default)
        end
    end
end

--- Read a config value
-- @param key string  config key name
-- @return value or nil
function config.get(key)
    return settings:readSetting(key)
end

--- Write a config value with normalization
-- @param key string  config key name
-- @param value any   value to store
function config.set(key, value)
    if key == "server" and type(value) == "string" then
        -- Strip trailing slash for consistent URL construction
        value = value:gsub("/+$", "")
    end
    settings:saveSetting(key, value)
end

--- Check if the plugin has been configured with required credentials
-- @return boolean
function config.is_configured()
    local server = settings:readSetting("server")
    local token = settings:readSetting("token")
    return server ~= nil and server ~= ""
        and token ~= nil and token ~= ""
end

--- Validate a server URL
-- @param url string
-- @return boolean ok
-- @return string|nil error message
function config.validate_server_url(url)
    if url == nil or url == "" then
        return false, "Server URL cannot be empty"
    end
    if not (url:match("^https?://")) then
        return false, "Server URL must start with http:// or https://"
    end
    return true
end

--- Get the underlying LuaSettings object (for flush/close)
-- @return LuaSettings
function config.get_settings()
    return settings
end

--- PocketBook native-player scan directory. The stock audiobook player scans
-- here, so writing downloads into it gives free native-player fallback playback.
-- USB-mounted view: /Volumes/PB700K3/Audio Books .
local NATIVE_PLAYER_DIR = "/mnt/ext1/Audio Books"

--- Dir-existence check (injectable for tests; default lfs-based).
-- Kept as a module field so tests can stub it without touching the filesystem.
config._exists_dir = function(path)
    local lfs_ok, lfs = pcall(require, "lfs")
    if not lfs_ok then lfs = _G.lfs end
    if not lfs then return false end
    return lfs.attributes(path, "mode") == "directory"
end

--- Persistent default download directory.
-- Prefers the PocketBook native-player directory (/mnt/ext1/Audio Books) when
-- it exists, so downloads are picked up by the stock audiobook player too
-- (free fallback playback + USB/Finder-visible). Otherwise falls back to a
-- subfolder of the persistent KOReader data dir. NEVER falls back to /tmp:
-- on PocketBook /tmp is not exposed via USB mass storage and may be tmpfs
-- (gone after reboot), so a /tmp default silently strands downloads.
-- @return string absolute directory path
function config.default_download_dir()
    if config._exists_dir(NATIVE_PLAYER_DIR) then
        return NATIVE_PLAYER_DIR
    end
    if DataStorage.getFullDataDir then
        return DataStorage:getFullDataDir() .. "/absaudio_books"
    elseif DataStorage.getDataDir then
        return DataStorage:getDataDir() .. "/absaudio_books"
    end
    return DataStorage:getSettingsDir() .. "/absaudio_books"
end

--- Resolve the effective download directory.
-- Returns the configured value when set and non-empty, otherwise the
-- persistent default (without persisting it — the caller or settings UI
-- decides whether to save). Replaces the old `config.get("download_dir")
-- or "/tmp/audiobooks"` silent-fallback pattern.
-- @return string absolute directory path
function config.get_download_dir()
    if settings then
        local dir = settings:readSetting("download_dir")
        if dir and type(dir) == "string" and dir:match("%S") then
            return dir
        end
    end
    return config.default_download_dir()
end

return config
