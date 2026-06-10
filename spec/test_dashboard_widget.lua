-- Dashboard widget tests
-- Tests dashboard_widget.lua public API: show, callback isolation
--
-- Run with: lua spec/test_dashboard_widget.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

------------------------------------------------------------------------
-- Stub all KOReader dependencies
------------------------------------------------------------------------

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

package.loaded["ffi/blitbuffer"] = {
    COLOR_WHITE = { white = true },
    COLOR_BLACK = { black = true },
    COLOR_DARK_GRAY = { dark_gray = true },
    COLOR_LIGHT_GRAY = { light_gray = true },
    COLOR_BLUE = { blue = true },
    COLOR_GRAY = { gray = true },
}

package.loaded["ui/bidi"] = {}

package.loaded["ui/widget/container/centercontainer"] = make_widget_stub()
package.loaded["ui/widget/focusmanager"] = make_class_stub()
package.loaded["ui/widget/container/framecontainer"] = make_widget_stub()
package.loaded["ui/widget/container/inputcontainer"] = make_widget_stub()
package.loaded["ui/widget/container/scrollablecontainer"] = make_widget_stub()
package.loaded["ui/widget/linewidget"] = make_widget_stub()
package.loaded["ui/widget/textboxwidget"] = make_widget_stub()
package.loaded["ui/widget/textwidget"] = make_widget_stub()
package.loaded["ui/widget/verticalgroup"] = make_widget_stub()
package.loaded["ui/widget/verticalspan"] = make_widget_stub()
package.loaded["ui/widget/infomessage"] = make_widget_stub()

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

------------------------------------------------------------------------
-- Mock dependencies
------------------------------------------------------------------------
package.loaded["abs_logger"] = {
    verbose = function() end,
    info = function() end,
    warn = function() end,
    set_level = function() end,
}

package.loaded["config"] = {
    get = function(key)
        if key == "preferred_format" then return "m4b" end
        return nil
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
}

package.loaded["manifest"] = {
    init = function() end,
    getRecentBook = function() return nil end,
    getAllBooks = function() return {} end,
}

package.loaded["absaudio/library_browser"] = {
    show = function() end,
}

package.loaded["absaudio/library_store"] = {
    wasLastFetchSuccessful = function() return true end,
}
package.loaded["absaudio/navigator"] = {
    register = function() end,
    push = function() end,
    pop = function() end,
    reset = function() end,
    _reset = function() end,
}

------------------------------------------------------------------------
-- Require module under test
------------------------------------------------------------------------
local dashboard = require("absaudio/dashboard_widget")
local mock = require("spec/test_helper")

------------------------------------------------------------------------
-- Test runner
------------------------------------------------------------------------
local passed = 0
local failed = 0
local errors = {}

local function run_test(name, fn)
    -- Reset mock state
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
-- Test: dashboard.show() creates a DashboardView instance
-- ============================================================
run_test("dashboard.show() creates a widget and passes it to UIManager", function()
    local shown_widgets = {}
    local orig_show = package.loaded["ui/uimanager"].show
    package.loaded["ui/uimanager"].show = function(self, widget)
        table.insert(shown_widgets, widget)
    end

    dashboard.show({
        on_settings = function() end,
        on_sync_now = function() end,
        on_export_diagnostics = function() end,
    })

    mock.assert_equals(#shown_widgets, 1, "should have shown one widget")
    mock.assert_equals(shown_widgets[1].name, "absaudio_dashboard", "widget should be DashboardView")

    package.loaded["ui/uimanager"].show = orig_show
end)

-- ============================================================
-- Test: callbacks are stored on the instance, not module-level
-- ============================================================
run_test("callbacks are stored on self via constructor", function()
    local shown_widgets = {}
    local orig_show = package.loaded["ui/uimanager"].show
    package.loaded["ui/uimanager"].show = function(self, widget)
        table.insert(shown_widgets, widget)
    end

    local settings_called = false
    local sync_called = false
    local export_called = false

    dashboard.show({
        on_settings = function() settings_called = true end,
        on_sync_now = function() sync_called = true end,
        on_export_diagnostics = function() export_called = true end,
    })

    local view = shown_widgets[#shown_widgets]
    mock.assert_equals(view ~= nil, true, "should have created a view widget")

    -- Verify callbacks are stored on the instance
    mock.assert_equals(type(view.on_settings), "function", "view should have on_settings function")
    mock.assert_equals(type(view.on_sync_now), "function", "view should have on_sync_now function")
    mock.assert_equals(type(view.on_export_diagnostics), "function", "view should have on_export_diagnostics function")

    -- Verify they are the actual callbacks
    view.on_settings()
    mock.assert_equals(settings_called, true, "on_settings callback should have been invoked")

    view.on_sync_now()
    mock.assert_equals(sync_called, true, "on_sync_now callback should have been invoked")

    view.on_export_diagnostics()
    mock.assert_equals(export_called, true, "on_export_diagnostics callback should have been invoked")

    package.loaded["ui/uimanager"].show = orig_show
end)

-- ============================================================
-- Test: callbacks default to nil when not provided
-- ============================================================
run_test("callbacks default to nil when show() is called without them", function()
    local shown_widgets = {}
    local orig_show = package.loaded["ui/uimanager"].show
    package.loaded["ui/uimanager"].show = function(self, widget)
        table.insert(shown_widgets, widget)
    end

    dashboard.show({})

    local view = shown_widgets[#shown_widgets]
    mock.assert_equals(view.on_settings, nil, "on_settings should be nil when not provided")
    mock.assert_equals(view.on_sync_now, nil, "on_sync_now should be nil when not provided")
    mock.assert_equals(view.on_export_diagnostics, nil, "on_export_diagnostics should be nil when not provided")

    package.loaded["ui/uimanager"].show = orig_show
end)

-- ============================================================
-- Test: callbacks are isolated between sequential show() calls
-- Verifies that two sequential show() calls with different callbacks
-- result in each instance using its own callbacks (isolation).
-- ============================================================
run_test("callbacks are isolated between sequential show() calls", function()
    -- Track which callback was invoked
    local settings_a_called = false
    local settings_b_called = false
    local sync_a_called = false
    local export_a_called = false

    -- Capture instances created by UIManager:show
    local shown_widgets = {}
    local orig_show = package.loaded["ui/uimanager"].show
    package.loaded["ui/uimanager"].show = function(self, widget)
        table.insert(shown_widgets, widget)
    end

    -- Show first dashboard with callback set A
    dashboard.show({
        on_settings = function() settings_a_called = true end,
        on_sync_now = function() sync_a_called = true end,
        on_export_diagnostics = function() export_a_called = true end,
    })

    local view_a = shown_widgets[#shown_widgets]
    mock.assert_equals(view_a ~= nil, true, "should have created first view widget")

    -- Show second dashboard with callback set B
    dashboard.show({
        on_settings = function() settings_b_called = true end,
        on_sync_now = nil,
        on_export_diagnostics = nil,
    })

    local view_b = shown_widgets[#shown_widgets]
    mock.assert_equals(view_b ~= nil, true, "should have created second view widget")

    -- view_a should use callbacks from set A
    view_a.on_settings()
    mock.assert_equals(settings_a_called, true, "view_a should call its own on_settings callback")
    mock.assert_equals(settings_b_called, false, "view_a should NOT call view_b's on_settings callback")

    -- view_b should use callbacks from set B
    view_b.on_settings()
    mock.assert_equals(settings_b_called, true, "view_b should call its own on_settings callback")

    -- view_b on_sync_now should be nil (was passed as nil)
    mock.assert_equals(view_b.on_sync_now, nil, "view_b on_sync_now should be nil")

    -- view_a still has its own callbacks intact
    view_a.on_sync_now()
    mock.assert_equals(sync_a_called, true, "view_a on_sync_now should still work")

    package.loaded["ui/uimanager"].show = orig_show
end)

-- ============================================================
-- Test: _onOpenSettings reads from self.on_settings
-- ============================================================
run_test("_onOpenSettings uses instance callback from self.on_settings", function()
    local shown_widgets = {}
    local orig_show = package.loaded["ui/uimanager"].show
    package.loaded["ui/uimanager"].show = function(self, widget)
        table.insert(shown_widgets, widget)
    end

    local settings_called = false
    dashboard.show({
        on_settings = function() settings_called = true end,
    })

    local view = shown_widgets[#shown_widgets]
    mock.assert_equals(view ~= nil, true, "should have created a view widget")

    -- Reset scheduled functions, then call _onOpenSettings which schedules the settings callback
    scheduled_fns = {}
    view:_onOpenSettings()

    -- Execute scheduled functions
    for _, fn in ipairs(scheduled_fns) do
        fn()
    end

    mock.assert_equals(settings_called, true, "_onOpenSettings should have invoked self.on_settings")

    package.loaded["ui/uimanager"].show = orig_show
end)

-- ============================================================
-- Test: _onSyncNow reads from self.on_sync_now
-- ============================================================
run_test("_onSyncNow uses instance callback from self.on_sync_now", function()
    local shown_widgets = {}
    local orig_show = package.loaded["ui/uimanager"].show
    package.loaded["ui/uimanager"].show = function(self, widget)
        table.insert(shown_widgets, widget)
    end

    local sync_called = false
    dashboard.show({
        on_sync_now = function() sync_called = true end,
    })

    local view = shown_widgets[#shown_widgets]
    view:_onSyncNow()

    mock.assert_equals(sync_called, true, "_onSyncNow should have invoked self.on_sync_now")

    package.loaded["ui/uimanager"].show = orig_show
end)

-- ============================================================
-- Test: _onExportDiagnostics reads from self.on_export_diagnostics
-- ============================================================
run_test("_onExportDiagnostics uses instance callback from self.on_export_diagnostics", function()
    local shown_widgets = {}
    local orig_show = package.loaded["ui/uimanager"].show
    package.loaded["ui/uimanager"].show = function(self, widget)
        table.insert(shown_widgets, widget)
    end

    local export_called = false
    dashboard.show({
        on_export_diagnostics = function() export_called = true end,
    })

    local view = shown_widgets[#shown_widgets]
    view:_onExportDiagnostics()

    mock.assert_equals(export_called, true, "_onExportDiagnostics should have invoked self.on_export_diagnostics")

    package.loaded["ui/uimanager"].show = orig_show
end)

-- ============================================================
-- Tests: dashboard.prepare() — data/render split
-- ============================================================

-- Helper: set up mock manifest with specific data
local function setup_manifest_mock(recent_book, all_books)
    package.loaded["manifest"] = {
        init = function() end,
        getRecentBook = function() return recent_book end,
        getAllBooks = function() return all_books end,
    }
end

run_test("prepare() returns data with recent_book and all_books when manifest has books", function()
    local test_book = {
        title = "Test Book",
        author = "Test Author",
        current_time = 120,
        duration = 3600,
    }
    local all_books = {
        test_book,
        { title = "Book 2", author = "Author 2" },
    }
    setup_manifest_mock(test_book, all_books)

    -- Reload the module to pick up new manifest mock
    package.loaded["absaudio/dashboard_widget"] = nil
    local dash = require("absaudio/dashboard_widget")

    local data, err = dash.prepare()

    mock.assert_equals(err, nil, "should not return error")
    mock.assert_equals(data ~= nil, true, "should return data table")
    mock.assert_equals(data.recent_book.title, "Test Book", "recent_book should match")
    mock.assert_equals(#data.all_books, 2, "all_books should have 2 entries")
end)

run_test("prepare() returns empty-but-valid data when manifest is empty", function()
    setup_manifest_mock(nil, {})  -- no recent book, no books

    package.loaded["absaudio/dashboard_widget"] = nil
    local dash = require("absaudio/dashboard_widget")

    local data, err = dash.prepare()

    mock.assert_equals(err, nil, "should not return error")
    mock.assert_equals(data ~= nil, true, "should return data table")
    mock.assert_equals(data.recent_book, nil, "recent_book should be nil")
    mock.assert_equals(#data.all_books, 0, "all_books should be empty array")
end)

run_test("prepare() handles manifest not available gracefully", function()
    -- Set manifest to nil to simulate it not being available
    package.loaded["manifest"] = nil

    package.loaded["absaudio/dashboard_widget"] = nil
    local dash = require("absaudio/dashboard_widget")

    local data, err = dash.prepare()

    mock.assert_equals(data, nil, "should not return data")
    mock.assert_equals(err ~= nil, true, "should return error info")
    mock.assert_equals(err.type, "manifest", "error type should be manifest")
end)

run_test("show() passes prepared data to DashboardView", function()
    local test_book = {
        title = "Prepared Book",
        author = "Prepared Author",
        current_time = 500,
        duration = 7200,
    }
    setup_manifest_mock(test_book, { test_book })

    package.loaded["absaudio/dashboard_widget"] = nil
    local dash = require("absaudio/dashboard_widget")

    local shown_widgets = {}
    local orig_show = package.loaded["ui/uimanager"].show
    package.loaded["ui/uimanager"].show = function(self, widget)
        table.insert(shown_widgets, widget)
    end

    dash.show({})

    mock.assert_equals(#shown_widgets, 1, "should have shown one widget")
    local view = shown_widgets[1]
    mock.assert_equals(view.dashboard_data ~= nil, true, "view should have dashboard_data")
    mock.assert_equals(view.dashboard_data.recent_book.title, "Prepared Book", "dashboard_data should contain prepared recent_book")
    mock.assert_equals(#view.dashboard_data.all_books, 1, "dashboard_data should contain prepared all_books")

    package.loaded["ui/uimanager"].show = orig_show
end)

-- ============================================================
-- Test: show() returns the view widget for navigator tracking
-- ============================================================
run_test("show() returns the view widget for navigator tracking", function()
    local shown_widgets = {}
    local orig_show = package.loaded["ui/uimanager"].show
    package.loaded["ui/uimanager"].show = function(self, widget)
        table.insert(shown_widgets, widget)
    end

    local returned = dashboard.show({})

    mock.assert_equals(returned ~= nil, true, "show should return the view widget")
    mock.assert_equals(returned.name, "absaudio_dashboard", "returned widget should be DashboardView")
    mock.assert_equals(returned, shown_widgets[#shown_widgets], "returned widget should be the same one shown to UIManager")

    package.loaded["ui/uimanager"].show = orig_show
end)

-- ============================================================
-- Test: _onBrowseLibrary uses nav.push instead of nested callbacks
-- ============================================================
run_test("_onBrowseLibrary calls nav.push('browser') instead of nested callbacks", function()
    local pushed = {}
    package.loaded["absaudio/navigator"].push = function(name, data)
        table.insert(pushed, { name = name, data = data })
    end

    local shown_widgets = {}
    local orig_show = package.loaded["ui/uimanager"].show
    package.loaded["ui/uimanager"].show = function(self, widget)
        table.insert(shown_widgets, widget)
    end

    dashboard.show({})
    local view = shown_widgets[#shown_widgets]
    view:_onBrowseLibrary()

    mock.assert_equals(#pushed, 1, "should have called nav.push once")
    mock.assert_equals(pushed[1].name, "browser", "should push 'browser' screen")
    mock.assert_equals(type(pushed[1].data), "table", "data should be a table")

    package.loaded["ui/uimanager"].show = orig_show
    package.loaded["absaudio/navigator"].push = function() end
end)

-- ============================================================
-- Test: _onBookTap pushes detail screen via navigator
-- ============================================================
run_test("_onBookTap pushes 'detail' screen with item.id mapped from abs_item_id", function()
    local pushed = {}
    package.loaded["absaudio/navigator"].push = function(name, data)
        table.insert(pushed, { name = name, data = data })
    end

    local shown_widgets = {}
    local orig_show = package.loaded["ui/uimanager"].show
    package.loaded["ui/uimanager"].show = function(self, widget)
        table.insert(shown_widgets, widget)
    end

    dashboard.show({})
    local view = shown_widgets[#shown_widgets]

    -- Simulate tapping a manifest book with abs_item_id
    local book = {
        abs_item_id = "abc-123",
        title = "Test Downloaded Book",
        author = "Test Author",
    }
    view:_onBookTap(book)

    mock.assert_equals(#pushed, 1, "should have called nav.push once")
    mock.assert_equals(pushed[1].name, "detail", "should push 'detail' screen")
    mock.assert_equals(pushed[1].data.item.id, "abc-123", "item.id should come from abs_item_id")
    mock.assert_equals(pushed[1].data.item.title, "Test Downloaded Book", "item.title should be preserved")

    package.loaded["ui/uimanager"].show = orig_show
    package.loaded["absaudio/navigator"].push = function() end
end)

run_test("downloaded book entries are wrapped in tappable containers that call _onBookTap", function()
    -- Set up manifest mock with two books (same pattern as other tests)
    setup_manifest_mock(nil, {
        { abs_item_id = "book-1", title = "Alpha Book", author = "Author A" },
        { abs_item_id = "book-2", title = "Beta Book", author = "Author B" },
    })

    -- Reload module to pick up new manifest mock
    package.loaded["absaudio/dashboard_widget"] = nil
    local dash = require("absaudio/dashboard_widget")

    local pushed = {}
    package.loaded["absaudio/navigator"].push = function(name, data)
        table.insert(pushed, { name = name, data = data })
    end

    local shown_widgets = {}
    local orig_show = package.loaded["ui/uimanager"].show
    package.loaded["ui/uimanager"].show = function(self, widget)
        table.insert(shown_widgets, widget)
    end

    dash.show({})
    local view = shown_widgets[#shown_widgets]

    -- Find tappable containers for books in the content_group
    local tap_containers = {}
    for _, el in ipairs(view.content_group) do
        if type(el) == "table" and el.ges_events and el.ges_events.TapBook then
            table.insert(tap_containers, el)
        end
    end

    mock.assert_equals(#tap_containers, 2, "should have 2 tappable book entries")

    -- Simulate tapping the first book
    tap_containers[1].onTapBook(tap_containers[1])
    mock.assert_equals(#pushed, 1, "should have called nav.push once")
    mock.assert_equals(pushed[1].name, "detail", "should push 'detail' screen")
    mock.assert_equals(pushed[1].data.item.id, "book-1", "item.id should be book-1's abs_item_id")

    -- Simulate tapping the second book
    tap_containers[2].onTapBook(tap_containers[2])
    mock.assert_equals(#pushed, 2, "should have called nav.push twice")
    mock.assert_equals(pushed[2].data.item.id, "book-2", "item.id should be book-2's abs_item_id")

    package.loaded["ui/uimanager"].show = orig_show
    package.loaded["absaudio/navigator"].push = function() end
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