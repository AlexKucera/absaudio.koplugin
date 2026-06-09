-- main.lua — Entry point for absaudio.koplugin
-- Registers the plugin with KOReader's menu system, handles first-run detection,
-- and presents the dashboard or settings dialog as appropriate.
--
-- Public interface: This is a KOReader plugin module. KOReader calls init()
-- and registers menu items automatically via the plugin loader.

local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local T = require("ffi/util").template

local config = require("config")
local abs_logger = require("abs_logger")
local error_handler = require("error_handler")

-- Try to load dashboard widget (may not exist yet in early dev)
local has_dashboard, dashboard = pcall(require, "absaudio/dashboard_widget")
local has_navigator, nav = pcall(require, "absaudio/navigator")

local ABSAudio = WidgetContainer:new{
    name = "absaudio",
}

--- Initialize plugin: register menu items and dispatcher actions
function ABSAudio:init()
    abs_logger.verbose("ABSAudio plugin initializing")

    -- Initialize config from LuaSettings
    config.init()

    -- Initialize API client if configured
    local has_api, api = pcall(require, "api")
    if has_api and config.is_configured() then
        api.init(config.get("server"), config.get("token"))
        abs_logger.verbose("API client initialized for " .. tostring(config.get("server")))
    end

    -- Register menu items (appears in KOReader's plugin menu)
    self.ui.menu:registerToMainMenu(self)

    -- Register dispatcher actions for gesture/shortcut binding
    self:onDispatcherRegisterActions()

    abs_logger.verbose("ABSAudio plugin initialized")
end

--- Register dispatcher actions
function ABSAudio:onDispatcherRegisterActions()
    Dispatcher:registerAction("absaudio_open", {
        category = "none",
        event = "ABSAudioOpen",
        title = _("ABS Audio: Open"),
        general = true,
    })
    Dispatcher:registerAction("absaudio_settings", {
        category = "none",
        event = "ABSAudioSettings",
        title = _("ABS Audio: Settings"),
        general = true,
    })
end

--- Menu entries shown in KOReader's hamburger menu → Plugins
function ABSAudio:addToMainMenu(menu_items)
    menu_items.absaudio = {
        text = _("ABS Audio"),
        sub_item_table = {
            {
                text = _("Open dashboard"),
                keep_menu_open = false,
                callback = function()
                    self:onOpenDashboard()
                end,
            },
            {
                text = _("Settings"),
                keep_menu_open = true,
                callback = function()
                    self:onShowSettings()
                end,
            },
        },
    }
end

--- Handle the ABSAudioOpen dispatcher event
function ABSAudio:onABSAudioOpen()
    self:onOpenDashboard()
    return true
end

--- Handle the ABSAudioSettings dispatcher event
function ABSAudio:onABSAudioSettings()
    self:onShowSettings()
    return true
end

--- Register all screens with the navigator
function ABSAudio:_registerScreens()
    if has_navigator and has_dashboard then
        nav.register("dashboard", dashboard.show)
    end
    local has_browser, browser = pcall(require, "absaudio/library_browser")
    if has_navigator and has_browser then
        nav.register("browser", browser.show)
    end
    local has_detail, detail = pcall(require, "absaudio/book_detail")
    if has_navigator and has_detail then
        nav.register("detail", detail.show)
    end
end

--- Open the main dashboard or settings dialog (first-run check)
function ABSAudio:onOpenDashboard()
    abs_logger.verbose("Opening dashboard")

    if not config.is_configured() then
        abs_logger.info("First run detected — showing settings dialog")
        self:onShowSettings()
        return
    end

    -- Set logger level from config
    abs_logger.set_level(config.get("log_level") or "verbose")

    -- Register screens with navigator
    self:_registerScreens()

    -- Show dashboard after menu closes (schedule to next event loop tick)
    -- The menu calls our callback synchronously, then closes itself after.
    -- By scheduling, we ensure the menu is gone before the dashboard renders.
    if has_dashboard then
        UIManager:scheduleIn(0.1, function()
            if has_navigator then
                nav.reset("dashboard", {
                    on_settings = function()
                        self:onShowSettings()
                    end,
                    on_sync_now = function()
                        self:onSyncNow()
                    end,
                    on_export_diagnostics = function()
                        self:onExportDiagnostics()
                    end,
                })
            else
                -- Fallback: call dashboard.show directly if navigator not available
                dashboard.show({
                    on_settings = function()
                        self:onShowSettings()
                    end,
                })
            end
        end)
    else
        -- Dashboard not yet available — show placeholder
        UIManager:show(InfoMessage:new{
            text = _("ABS Audio dashboard will appear here.\n\nSections: Resume Last Book, Downloaded Books, Browse Library, Settings"),
            timeout = 5,
        })
    end
end
--- Show the settings dialog with all config fields
function ABSAudio:onShowSettings()
    abs_logger.verbose("Showing settings dialog")

    local settings_dialog
    settings_dialog = MultiInputDialog:new{
        title = _("ABS Audio Settings"),
        fields = {
            {
                description = _("Server URL (e.g. https://abs.example.com)"),
                text = config.get("server") or "",
                hint = "https://abs.example.com",
            },
            {
                description = _("API Token"),
                text = config.get("token") or "",
                hint = _("Your ABS API key"),
            },
            {
                description = _("Download Directory"),
                text = config.get("download_dir") or "",
                hint = "/mnt/ext1/audiobooks",
            },
            {
                description = _("Preferred Format"),
                text = config.get("preferred_format") or "m4b",
                hint = "m4b",
            },
            {
                description = _("Log Level"),
                text = config.get("log_level") or "verbose",
                hint = "verbose / info / warn",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(settings_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local fields = settings_dialog:getFields()
                        self:onSaveSettings(fields)
                    end,
                },
            },
            {
                {
                    text = _("Clear cover cache"),
                    callback = function()
                        local library_browser = require("absaudio/library_browser")
                        local count = library_browser.clearCoverCache()
                        UIManager:show(require("ui/widget/infomessage"):new{
                            text = count > 0
                                and T(_("Cleared %1 cached cover images."), count)
                                or _("No cached covers found."),
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(settings_dialog)
    settings_dialog:onShowKeyboard()
end

--- Save settings with validation
-- @param fields table  ordered array of field values from MultiInputDialog
function ABSAudio:onSaveSettings(fields)
    -- Guard: this handler can be invoked by KOReader close/shutdown events
    -- where no dialog fields are provided. Only process when called from
    -- the MultiInputDialog callback with actual field data.
    if not fields then return end
    local server_url = fields[1] and fields[1]:match("^%s*(.-)%s*$") or ""
    local token = fields[2] and fields[2]:match("^%s*(.-)%s*$") or ""
    local download_dir = fields[3] and fields[3]:match("^%s*(.-)%s*$") or ""
    local preferred_format = fields[4] and fields[4]:match("^%s*(.-)%s*$") or "m4b"
    local log_level = fields[5] and fields[5]:match("^%s*(.-)%s*$") or "verbose"

    abs_logger.verbose("Validating settings...")

    -- Validate server URL
    local ok, err = config.validate_server_url(server_url)
    if not ok then
        UIManager:show(InfoMessage:new{
            text = T(_("Invalid server URL: %1"), err),
            timeout = 5,
        })
        return
    end

    -- Validate token
    if token == "" then
        UIManager:show(InfoMessage:new{
            text = _("API token cannot be empty."),
            timeout = 5,
        })
        return
    end

    -- Validate credential by calling ABS API
    abs_logger.info("Validating credentials against ABS server...")
    self:validateCredentials(server_url, token, function(success)
        if success then
            -- Save all settings
            config.set("server", server_url)
            config.set("token", token)
            if download_dir ~= "" then
                config.set("download_dir", download_dir)
            end
            config.set("preferred_format", preferred_format)
            config.set("log_level", log_level)
            config.get_settings():flush()

            -- Re-initialize API client with new credentials
            local has_api_mod, api_mod = pcall(require, "api")
            if has_api_mod then
                api_mod.init(server_url, token)
            end

            -- Update logger level
            abs_logger.set_level(log_level)

            abs_logger.info("Settings saved successfully")
            UIManager:show(InfoMessage:new{
                text = _("Settings saved. Connection verified!"),
                timeout = 3,
            })
        else
            abs_logger.warn("Credential validation failed")
            error_handler.show("auth", "Connection test failed. Please verify your server URL and API token.")
        end
    end)
end

--- Sync Now handler (stub)
function ABSAudio:onSyncNow()
    abs_logger.info("Sync Now triggered from dashboard")
    UIManager:show(InfoMessage:new{
        text = _("Sync will be available in a future update."),
        timeout = 3,
    })
end

--- Export Diagnostics handler (stub)
function ABSAudio:onExportDiagnostics()
    abs_logger.info("Export Diagnostics triggered from dashboard")
    UIManager:show(InfoMessage:new{
        text = _("Export Diagnostics will be available in a future update."),
        timeout = 3,
    })
end

--- Validate credentials by calling GET /api/libraries
-- @param server_url string
-- @param token string
-- @param callback function(success: boolean)
function ABSAudio:validateCredentials(server_url, token, callback)
    -- Use socketutil + socket.http for the API call
    -- Pattern from naleo: socketutil:set_timeout() → pcall(socket.http.request) → socketutil:reset_timeout()
    local socketutil_ok, socketutil = pcall(require, "socketutil")
    if not socketutil_ok then
        abs_logger.warn("socketutil not available — skipping validation")
        callback(false)
        return
    end

    local socket_http = require("socket.http")
    local ltn12 = require("ltn12")
    local json = require("json") -- KOReader includes dkjson

    local url = server_url .. "/api/libraries"
    local response_body = {}

    abs_logger.verbose("GET " .. url)

    socketutil:set_timeout(10, 15)

    local request = {
        url = url,
        method = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. token,
            ["Accept"] = "application/json",
        },
        sink = ltn12.sink.table(response_body),
    }

    local ok, code_or_error = pcall(function()
        local _, status_code = socket_http.request(request)
        return status_code
    end)

    socketutil:reset_timeout()

    if ok and type(code_or_error) == "number" and code_or_error >= 200 and code_or_error < 300 then
        abs_logger.info("Credential validation successful (HTTP " .. tostring(code_or_error) .. ")")
        callback(true)
    else
        local err_msg = ok and tostring(code_or_error) or tostring(code_or_error)
        abs_logger.warn("Credential validation failed: " .. err_msg)
        callback(false)
    end
end

return ABSAudio
