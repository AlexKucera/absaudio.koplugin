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

return config
