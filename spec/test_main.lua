-- main.lua tests
-- Tests plugin initialization, navigator registration, and onOpenDashboard wiring
--
-- Run with: lua spec/test_main.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

------------------------------------------------------------------------
-- Stub all KOReader dependencies
------------------------------------------------------------------------

package.loaded["ffi/blitbuffer"] = {
    COLOR_WHITE = { white = true },
    COLOR_BLACK = { black = true },
    COLOR_DARK_GRAY = { dark_gray = true },
    COLOR_LIGHT_GRAY = { light_gray = true },
    COLOR_BLUE = { blue = true },
    COLOR_GRAY = { gray = true },
    COLOR_DARK_GREEN = { dark_green = true },
}

package.loaded["ui/bidi"] = {}

-- Helper: create a widget stub whose new() returns a table with getSize()
local function make_widget_stub()
    return {
        new = function(self, opts)
            local obj = opts or {}
            obj.ges_events = obj.ges_events or {}
            obj.key_events = obj.key_events or {}
            obj.getSize = function() return { w = 100, h = 20 } end
            return obj
        end,
    }
end

-- KOReader class system stub
local function make_class_stub()
    local mt = {}
    mt.__index = mt
    function mt:extend(class_def)
        local cls = setmetatable(class_def or {}, { __index = self })
        cls.new = function(self_obj, opts)
            local obj = setmetatable(opts or {}, { __index = cls })
            obj.getSize = function() return { w = 100, h = 20 } end
            if obj.init then obj:init() end
            return obj
        end
        return cls
    end
    return mt
end

package.loaded["ui/widget/container/centercontainer"] = make_widget_stub()
package.loaded["ui/widget/container/framecontainer"] = make_widget_stub()
package.loaded["ui/widget/container/inputcontainer"] = make_widget_stub()
package.loaded["ui/widget/container/scrollablecontainer"] = make_widget_stub()
-- WidgetContainer class stub — supports :new{} and method inheritance
local WC_mt = {}
WC_mt.__index = WC_mt
function WC_mt:new(opts)
    local obj = setmetatable(opts or {}, { __index = self })
    return obj
end
function WC_mt:extend(class_def)
    local cls = setmetatable(class_def or {}, { __index = self })
    cls.new = function(self_obj, opts2)
        local obj = setmetatable(opts2 or {}, { __index = cls })
        return obj
    end
    return cls
end
package.loaded["ui/widget/container/widgetcontainer"] = WC_mt
package.loaded["ui/widget/verticalgroup"] = make_widget_stub()
package.loaded["ui/widget/verticalspan"] = make_widget_stub()
package.loaded["ui/widget/horizontalgroup"] = make_widget_stub()
package.loaded["ui/widget/horizontalspan"] = make_widget_stub()
package.loaded["ui/widget/linewidget"] = make_widget_stub()
package.loaded["ui/widget/textboxwidget"] = make_widget_stub()
package.loaded["ui/widget/textwidget"] = make_widget_stub()
package.loaded["ui/widget/imagewidget"] = make_widget_stub()
package.loaded["ui/widget/iconwidget"] = make_widget_stub()
package.loaded["ui/widget/infomessage"] = make_widget_stub()
local mid_stub = {
    new = function(self, opts)
        local obj = opts or {}
        obj.ges_events = obj.ges_events or {}
        obj.key_events = obj.key_events or {}
        obj.getSize = function() return { w = 100, h = 20 } end
        obj.onShowKeyboard = function() end
        obj.getFields = function() return {} end
        return obj
    end,
}
package.loaded["ui/widget/multiinputdialog"] = mid_stub
package.loaded["ui/widget/inputdialog"] = make_widget_stub()
package.loaded["ui/widget/container/leftcontainer"] = make_widget_stub()
package.loaded["ui/widget/focusmanager"] = make_class_stub()


local mock_device = {
    hasKeys = function() return true end,
    isTouchDevice = function() return true end,
    input = { group = { Back = "Back" } },
    screen = {
        getSize = function() return { w = 600, h = 800 } end,
        scaleBySize = function(n) return n end,
    },
}
package.loaded["device"] = mock_device
package.loaded["ui/device"] = mock_device

package.loaded["ui/font"] = {
    getFace = function(name, size) return { name = name, size = size } end,
}

package.loaded["ui/geometry"] = {
    new = function(opts) return opts or {} end,
}

package.loaded["ui/gesturerange"] = {
    new = function(opts) return opts or {} end,
}

package.loaded["ui/size"] = {
    padding = { large = 10, default = 5, small = 2 },
    line = { thin = 1 },
}

local scheduled_fns = {}
package.loaded["ui/uimanager"] = {
    show = function() end,
    close = function() end,
    scheduleIn = function(self, delay, fn)
        table.insert(scheduled_fns, fn)
    end,
}

package.loaded["gettext"] = function(s) return s end

package.loaded["ffi/util"] = {
    template = function(s, ...)
        return s
    end,
}

package.loaded["dispatcher"] = {
    registerAction = function() end,
}

------------------------------------------------------------------------
-- Mock project dependencies
------------------------------------------------------------------------
package.loaded["abs_logger"] = {
    verbose = function() end,
    info = function() end,
    warn = function() end,
    set_level = function() end,
}

package.loaded["config"] = {
    init = function() end,
    get = function(key)
        if key == "server" then return "https://abs.example.com" end
        if key == "token" then return "test-token" end
        if key == "log_level" then return "verbose" end
        if key == "preferred_format" then return "m4b" end
        return nil
    end,
    set = function() end,
    is_configured = function() return true end,
    validate_server_url = function(url) return true end,
    get_settings = function()
        return { flush = function() end }
    end,
}

package.loaded["error_handler"] = {
    show = function() end,
    show_api_error = function() end,
    get_user_message = function(error_type, details)
        return error_type .. ": " .. tostring(details)
    end,
}

package.loaded["api"] = {
    is_configured = function() return true end,
    init = function() end,
    getItemDetails = function() return true, {} end,
    getLibraries = function()
        return true, { libraries = { { id = "lib_test" } } }
    end,
}

package.loaded["manifest"] = {
    init = function() end,
    getRecentBook = function() return nil end,
    getAllBooks = function() return {} end,
    getBook = function() return nil end,
}

package.loaded["absaudio/library_store"] = {
    init = function() end,
    fetchAll = function() return true end,
    getItems = function()
        return { items = {}, page = 1, per_page = 25, total_pages = 1, total_items = 0 }
    end,
    getSortModes = function() return {} end,
    getCurrentSort = function() return "title_asc" end,
    setSort = function() end,
    isLoaded = function() return false end,
    getItemTitle = function(item) return item.title or "" end,
    getItemAuthor = function(item) return item.author or "" end,
    wasLastFetchSuccessful = function() return true end,
}

package.loaded["absaudio/cover_cache"] = {
    init = function() end,
    hasCachedCover = function() return false end,
    getCoverPath = function() return nil end,
    fetchAndCache = function() return false end,
}

------------------------------------------------------------------------
-- Mock navigator — captures registration calls
------------------------------------------------------------------------
local nav_registrations = {}
local nav_resets = {}

package.loaded["absaudio/navigator"] = {
    register = function(name, show_fn)
        table.insert(nav_registrations, { name = name, show_fn = show_fn })
    end,
    push = function() end,
    pop = function() end,
    reset = function(name, data)
        table.insert(nav_resets, { name = name, data = data })
    end,
    _reset = function() end,
}

------------------------------------------------------------------------
-- Require module under test
------------------------------------------------------------------------
local ABSAudio = require("main")
local mock = require("spec/test_helper")

------------------------------------------------------------------------
-- Test runner
------------------------------------------------------------------------
local passed = 0
local failed = 0
local errors = {}

local function run_test(name, fn)
    -- Reset mock state
    nav_registrations = {}
    nav_resets = {}
    scheduled_fns = {}

    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("  ✓ " .. name)
    else
        failed = failed + 1
        table.insert(errors, { name = name, err = err })
        print("  ✗ " .. name)
        print("    " .. tostring(err))
    end
end

-- ============================================================
-- Test: ABSAudio is a WidgetContainer with correct name
-- ============================================================
run_test("ABSAudio is a WidgetContainer with name 'absaudio'", function()
    mock.assert_equals(ABSAudio.name, "absaudio", "plugin name should be 'absaudio'")
end)

-- ============================================================
-- Test: _registerScreens registers all 3 screens with navigator
-- ============================================================
run_test("_registerScreens registers dashboard, browser, detail with navigator", function()
    -- Create a plugin instance with a mock ui.menu
    local plugin = ABSAudio:new{
        ui = { menu = { registerToMainMenu = function() end } },
    }

    plugin:_registerScreens()

    mock.assert_equals(#nav_registrations, 3, "should register 3 screens")
    mock.assert_equals(nav_registrations[1].name, "dashboard", "first screen should be dashboard")
    mock.assert_equals(nav_registrations[2].name, "browser", "second screen should be browser")
    mock.assert_equals(nav_registrations[3].name, "detail", "third screen should be detail")
end)

-- ============================================================
-- Test: _registerScreens registers show functions, not bare data
-- ============================================================
run_test("_registerScreens registers callable show functions", function()
    local plugin = ABSAudio:new{
        ui = { menu = { registerToMainMenu = function() end } },
    }

    plugin:_registerScreens()

    for _, reg in ipairs(nav_registrations) do
        mock.assert_equals(type(reg.show_fn), "function",
            "screen '" .. reg.name .. "' should have a function show_fn")
    end
end)

-- ============================================================
-- Test: onOpenDashboard calls _registerScreens before showing
-- ============================================================
run_test("onOpenDashboard calls _registerScreens when configured", function()
    local plugin = ABSAudio:new{
        ui = { menu = { registerToMainMenu = function() end } },
    }

    plugin:onOpenDashboard()

    -- _registerScreens should have been called (registers screens)
    mock.assert_equals(#nav_registrations, 3, "should have registered 3 screens")
end)

-- ============================================================
-- Test: onOpenDashboard schedules nav.reset with dashboard data
-- ============================================================
run_test("onOpenDashboard schedules nav.reset('dashboard', data) via UIManager", function()
    local plugin = ABSAudio:new{
        ui = { menu = { registerToMainMenu = function() end } },
    }

    plugin:onOpenDashboard()

    -- The dashboard show is scheduled via UIManager:scheduleIn
    mock.assert_equals(#scheduled_fns, 1, "should have scheduled one function")

    -- Execute the scheduled function
    scheduled_fns[1]()

    -- nav.reset should have been called
    mock.assert_equals(#nav_resets, 1, "should have called nav.reset once")
    mock.assert_equals(nav_resets[1].name, "dashboard", "should reset to 'dashboard' screen")
end)

-- ============================================================
-- Test: onOpenDashboard passes on_settings in dashboard data
-- ============================================================
run_test("onOpenDashboard passes on_settings callback in dashboard data", function()
    local plugin = ABSAudio:new{
        ui = { menu = { registerToMainMenu = function() end } },
    }

    plugin:onOpenDashboard()
    scheduled_fns[1]()

    mock.assert_equals(#nav_resets, 1, "should have called nav.reset")
    local data = nav_resets[1].data
    mock.assert_equals(type(data.on_settings), "function", "data should have on_settings function")
    mock.assert_equals(type(data.on_sync_now), "function", "data should have on_sync_now function")
    mock.assert_equals(type(data.on_export_diagnostics), "function", "data should have on_export_diagnostics function")
end)

-- ============================================================
-- Test: onOpenDashboard shows settings dialog on first run
-- ============================================================
run_test("onOpenDashboard shows settings dialog when not configured", function()
    -- Override config to simulate first run
    local orig_is_configured = package.loaded["config"].is_configured
    package.loaded["config"].is_configured = function() return false end

    -- Reload main.lua to pick up the new config mock
    package.loaded["main"] = nil
    local ABSAudio2 = require("main")

    local shown_widgets = {}
    local orig_show = package.loaded["ui/uimanager"].show
    package.loaded["ui/uimanager"].show = function(self, widget)
        table.insert(shown_widgets, widget)
    end

    local plugin = ABSAudio2:new{
        ui = { menu = { registerToMainMenu = function() end } },
    }

    plugin:onOpenDashboard()

    -- Should have shown something (settings dialog) without scheduling
    mock.assert_equals(#shown_widgets >= 1, true, "should show settings dialog on first run")
    mock.assert_equals(#scheduled_fns, 0, "should NOT schedule dashboard on first run")

    -- Restore
    package.loaded["ui/uimanager"].show = orig_show
    package.loaded["config"].is_configured = orig_is_configured
    package.loaded["main"] = nil
end)

-- ============================================================
-- Test: menu entries include Open dashboard and Settings
-- ============================================================
run_test("addToMainMenu creates absaudio menu with Open dashboard and Settings", function()
    local menu_items = {}
    local plugin = ABSAudio:new{
        ui = { menu = { registerToMainMenu = function() end } },
    }

    plugin:addToMainMenu(menu_items)

    mock.assert_equals(menu_items.absaudio ~= nil, true, "should create absaudio menu entry")
    mock.assert_equals(menu_items.absaudio.text, "ABS Audio", "menu text should be 'ABS Audio'")
    mock.assert_equals(#menu_items.absaudio.sub_item_table, 2, "should have 2 sub-items")
    mock.assert_equals(menu_items.absaudio.sub_item_table[1].text, "Open dashboard",
        "first item should be 'Open dashboard'")
    mock.assert_equals(menu_items.absaudio.sub_item_table[2].text, "Settings",
        "second item should be 'Settings'")
end)

-- ============================================================
-- Test: dispatcher events route to correct handlers
-- ============================================================
run_test("ABSAudioOpen event routes to onOpenDashboard", function()
    local plugin = ABSAudio:new{
        ui = { menu = { registerToMainMenu = function() end } },
    }

    -- Track that onOpenDashboard was called
    local dashboard_called = false
    local orig = plugin.onOpenDashboard
    plugin.onOpenDashboard = function(self)
        dashboard_called = true
    end

    plugin:onABSAudioOpen()
    mock.assert_equals(dashboard_called, true, "ABSAudioOpen should call onOpenDashboard")

    plugin.onOpenDashboard = orig
end)

run_test("ABSAudioSettings event routes to onShowSettings", function()
    local plugin = ABSAudio:new{
        ui = { menu = { registerToMainMenu = function() end } },
    }

    local settings_called = false
    local orig = plugin.onShowSettings
    plugin.onShowSettings = function(self)
        settings_called = true
    end

    plugin:onABSAudioSettings()
    mock.assert_equals(settings_called, true, "ABSAudioSettings should call onShowSettings")

    plugin.onShowSettings = orig
end)

-- ============================================================
-- Summary
-- ============================================================
print(string.format("\n%d passed, %d failed", passed, failed))

if #errors > 0 then
    print("\nFailures:")
    for _, e in ipairs(errors) do
        print("  " .. e.name .. ": " .. tostring(e.err))
    end
    os.exit(1)
end
