-- Error handler for absaudio.koplugin
-- Maps internal error types to user-facing dialogs. Never crashes KOReader.
--
-- Public API:
--   error_handler.show(error_type, details)  -- show error dialog to user
--   error_handler.get_user_message(error_type, details) -- get message without showing
--
-- Error types: "network", "auth", "filesystem", "api", "unknown"

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local error_handler = {}

-- Maps error types to user-friendly messages
local ERROR_MESSAGES = {
    network = _("Network error: Could not connect to server. Please check your connection and server URL."),
    auth = _("Authentication failed. Please check your API token in settings."),
    filesystem = _("Storage error: Could not access or write to the download directory."),
    api = _("Server returned an error. Please try again later."),
    unknown = _("An unexpected error occurred."),
}

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

return error_handler
