-- Error handler for absaudio.koplugin
-- Maps internal error types and HTTP status codes to user-facing dialogs.
-- Never crashes KOReader.
--
-- Public API:
--   error_handler.show(error_type, details)              -- show error dialog
--   error_handler.get_user_message(error_type, details)  -- get message without showing
--   error_handler.from_api_error(api_error)              -- create from API client error table
--
-- Error types: "network", "auth", "not_found", "filesystem", "api", "parse", "unknown"
-- Return convention: void for show(); direct value (string) for get_user_message(); direct value (table) for from_api_error().

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local error_handler = {}

-- Maps error types to user-friendly messages
local ERROR_MESSAGES = {
    network = _("Network error: Could not connect to server. Please check your connection and server URL."),
    auth = _("Authentication failed. Please check your server URL and API token in Settings."),
    not_found = _("Item not found on server. It may have been removed."),
    filesystem = _("Storage error: Could not access or write to the download directory."),
    api = _("Server returned an error. Please try again later."),
    parse = _("Unexpected response from server."),
    server = _("Server error. Please try again later."),
    unknown = _("An unexpected error occurred."),
}

-- Maps HTTP status codes to error types and messages
local HTTP_ERROR_MAP = {
    [401] = { type = "auth",      message = _("Check your server URL and API token in Settings.") },
    [403] = { type = "auth",      message = _("Check your server URL and API token in Settings.") },
    [404] = { type = "not_found", message = _("Item not found on server. It may have been removed.") },
    [429] = { type = "api",       message = _("Too many requests. Please wait and try again.") },
}

--- Classify an HTTP status code into an error type
-- @param status_code number
-- @return string  error type
-- @return string  user-facing message
function error_handler.classify_http_status(status_code)
    local mapped = HTTP_ERROR_MAP[status_code]
    if mapped then
        return mapped.type, mapped.message
    end
    if status_code >= 500 then
        return "server", _("Server error. Please try again later.")
    end
    if status_code >= 400 then
        return "api", _("Unexpected response from server (HTTP %d)."):format(status_code)
    end
    return "unknown", _("Unexpected error (HTTP %d)."):format(status_code)
end

--- Build a user-facing message from an API client error table
-- @param api_error table  {type, status_code, message} from api.lua
-- @return string  user-facing message
function error_handler.from_api_error(api_error)
    if type(api_error) ~= "table" then
        return ERROR_MESSAGES.unknown
    end

    -- If it has an HTTP status code, use the HTTP mapping
    if api_error.status_code then
        local _, msg = error_handler.classify_http_status(api_error.status_code)
        return msg
    end

    -- Fall back to type-based mapping
    local template = ERROR_MESSAGES[api_error.type] or ERROR_MESSAGES.unknown
    if api_error.message and api_error.message ~= "" then
        return template .. "\n\n" .. api_error.message
    end
    return template
end

--- Build a user-facing message for the error
-- @param error_type string  error category
-- @param details string|nil  technical details (shown in message)
-- @return string  user-facing message
function error_handler.get_user_message(error_type, details)
    local template = ERROR_MESSAGES[error_type] or ERROR_MESSAGES.unknown
    if details and details ~= "" then
        return template .. "\n\n" .. tostring(details)
    end
    return template
end

--- Show an error dialog to the user
-- @param error_type string  error category
-- @param details string|nil  technical details
function error_handler.show(error_type, details)
    local msg = error_handler.get_user_message(error_type, details)
    UIManager:show(InfoMessage:new{
        text = msg,
        timeout = 10,
    })
end

--- Show an error dialog from an API client error table
-- @param api_error table  {type, status_code, message} from api.lua
function error_handler.show_api_error(api_error)
    local msg = error_handler.from_api_error(api_error)
    UIManager:show(InfoMessage:new{
        text = msg,
        timeout = 10,
    })
end

return error_handler
