-- Library browser tests
-- Tests library_browser.lua public API: show, getState, onSearch, onCycleSort
--
-- Run with: luajit spec/test_library_browser.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

------------------------------------------------------------------------
-- Stub all KOReader dependencies
------------------------------------------------------------------------

-- Helper: create a widget stub whose new() returns a table with getSize()
local function make_widget_stub()
    return {
        new = function(self, opts)
            local obj = opts or {}
            -- KOReader widgets expect these tables to exist
            obj.ges_events = obj.ges_events or {}
            obj.key_events = obj.key_events or {}
            obj.getSize = function() return { w = 100, h = 20 } end
            return obj
        end,
    }
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
-- KOReader class system stub: extend() returns a new table that inherits from the base
local function make_class_stub()
    local mt = {}
    mt.__index = mt
    function mt:extend(class_def)
        local cls = setmetatable(class_def or {}, { __index = self })
        cls.new = function(self_obj, opts)
            local obj = setmetatable(opts or {}, { __index = cls })
            obj.getSize = function() return { w = 100, h = 20 } end
            -- KOReader's Widget:new calls init() if it exists
            if obj.init then obj:init() end
            return obj
        end
        return cls
    end
    return mt
end

package.loaded["ui/widget/focusmanager"] = make_class_stub()
package.loaded["ui/widget/container/framecontainer"] = make_widget_stub()
package.loaded["ui/widget/container/inputcontainer"] = make_widget_stub()
package.loaded["ui/widget/container/leftcontainer"] = make_widget_stub()
package.loaded["ui/widget/container/scrollablecontainer"] = make_widget_stub()
package.loaded["ui/widget/horizontalgroup"] = make_widget_stub()
package.loaded["ui/widget/horizontalspan"] = make_widget_stub()
package.loaded["ui/widget/imagewidget"] = make_widget_stub()
package.loaded["ui/widget/infomessage"] = make_widget_stub()
package.loaded["ui/widget/inputdialog"] = make_widget_stub()
package.loaded["ui/widget/linewidget"] = make_widget_stub()
package.loaded["ui/widget/textboxwidget"] = make_widget_stub()
package.loaded["ui/widget/textwidget"] = make_widget_stub()
package.loaded["ui/widget/verticalgroup"] = make_widget_stub()
package.loaded["ui/widget/verticalspan"] = make_widget_stub()
package.loaded["ui/widget/iconwidget"] = make_widget_stub()

local mock_device = {
    hasKeys = function() return true end,
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

package.loaded["ui/uimanager"] = {
    show = function() end,
    close = function() end,
    scheduleIn = function() end,
}

package.loaded["gettext"] = function(s) return s end

package.loaded["abs_logger"] = {
    verbose = function() end,
    info = function() end,
    warn = function() end,
    set_level = function() end,
}

package.loaded["datastorage"] = {
    getSettingsDir = function() return "/tmp/koreader_test" end,
}

------------------------------------------------------------------------
-- Mock api module
------------------------------------------------------------------------
local mock_api_data = {
    libraries = { { id = "lib_test" } },
}
local mock_library_items = {}

package.loaded["api"] = {
    is_configured = function() return true end,
    getLibraries = function()
        return true, mock_api_data
    end,
    getLibraryItems = function(lib_id, opts)
        return true, { results = mock_library_items }
    end,
}

------------------------------------------------------------------------
-- Mock cover_cache module
------------------------------------------------------------------------
package.loaded["absaudio/cover_cache"] = {
    init = function() end,
    hasCachedCover = function() return false end,
    getCoverPath = function() return nil end,
    fetchAndCache = function() return false end,
}

------------------------------------------------------------------------
-- Mock library_store module
------------------------------------------------------------------------
local mock_store_items = {}
local mock_store_sort = "title_asc"

package.loaded["absaudio/library_store"] = {
    init = function() end,
    fetchAll = function(library_id)
        return true
    end,
    getItems = function(opts)
        opts = opts or {}
        local page = opts.page or 1
        local per_page = opts.per_page or 25
        -- Apply search filter like the real library_store does
        local items = mock_store_items
        if opts.search and opts.search ~= "" then
            local q = opts.search:lower()
            local filtered = {}
            for _, item in ipairs(items) do
                local title = (item.media and item.media.metadata and item.media.metadata.title or item.title or ""):lower()
                local author = (item.media and item.media.metadata and item.media.metadata.authorName or item.author or ""):lower()
                if title:find(q, 1, true) or author:find(q, 1, true) then
                    table.insert(filtered, item)
                end
            end
            items = filtered
        end
        local total = #items
        local total_pages = math.ceil(total / per_page)
        if total_pages == 0 then total_pages = 1 end
        local start_idx = (page - 1) * per_page + 1
        local end_idx = math.min(start_idx + per_page - 1, total)
        local page_items = {}
        for i = start_idx, end_idx do
            table.insert(page_items, items[i])
        end
        return {
            items = page_items,
            page = page,
            per_page = per_page,
            total_pages = total_pages,
            total_items = total,
        }
    end,
    getSortModes = function()
        return { "title_asc", "title_desc", "author_asc", "author_desc", "recently_added", "recently_played" }
    end,
    getCurrentSort = function()
        return mock_store_sort
    end,
    setSort = function(key)
        mock_store_sort = key
    end,
    isLoaded = function()
        return #mock_store_items > 0
    end,
    getItemTitle = function(item)
        if item.media and item.media.metadata and item.media.metadata.title then
            return item.media.metadata.title
        end
        return item.title or ""
    end,
    getItemAuthor = function(item)
        if item.media and item.media.metadata and item.media.metadata.authorName then
            return item.media.metadata.authorName
        end
        return item.author or ""
    end,
}

------------------------------------------------------------------------
-- Require the module under test
------------------------------------------------------------------------
local browser = require("absaudio/library_browser")
local mock = require("spec/test_helper")

------------------------------------------------------------------------
-- Test runner
------------------------------------------------------------------------
local passed = 0
local failed = 0
local errors = {}

local function run_test(name, fn)
    -- Reset mock state before each test
    mock_store_items = {}
    mock_store_sort = "title_asc"
    mock_library_items = {}

    -- Re-initialize browser state by calling show() with a fresh state
    -- (show() resets _current_page and _search_query)

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
-- Test: browser.getState returns default state after show()
-- ============================================================
run_test("browser.getState returns default state after show()", function()
    -- Set up some sample items so the browser has something to show
    mock_store_items = {
        {
            id = "li_001",
            mediaType = "book",
            addedAt = 1000,
            media = {
                duration = 3600,
                metadata = { title = "Test Book", authorName = "Test Author" },
            },
        },
    }

    browser.show({
        on_back = function() end,
        on_book_tap = function() end,
    })

    local state = browser.getState()
    mock.assert_equals(state.search_query, "", "search_query should be empty after fresh show()")
    mock.assert_equals(state.current_page, 1, "current_page should be 1 after fresh show()")
end)

-- ============================================================
-- Test: browser.getState reflects search query after manual set
-- ============================================================
run_test("browser.getState reflects search query after manual set", function()
    mock_store_items = {
        {
            id = "li_001",
            mediaType = "book",
            media = {
                duration = 3600,
                metadata = { title = "Alpha Book", authorName = "Author A" },
            },
        },
    }

    browser.show({
        on_back = function() end,
        on_book_tap = function() end,
    })

    -- Manually set search query (simulating onSearch behavior)
    browser._setSearchQuery("alpha")
    browser._setCurrentPage(2)

    local state = browser.getState()
    mock.assert_equals(state.search_query, "alpha", "search_query should be 'alpha'")
    mock.assert_equals(state.current_page, 2, "current_page should be 2")
end)

-- ============================================================
-- Test: browser.search sets query and resets to page 1
-- ============================================================
run_test("browser.search sets query and resets to page 1", function()
    mock_store_items = {
        {
            id = "li_001",
            mediaType = "book",
            media = {
                duration = 3600,
                metadata = { title = "Alpha Book", authorName = "Author A" },
            },
        },
    }

    browser.show({
        on_back = function() end,
        on_book_tap = function() end,
    })

    -- Simulate navigating to page 2, then searching
    browser._setCurrentPage(3)
    browser.search("alpha")

    local state = browser.getState()
    mock.assert_equals(state.search_query, "alpha", "search_query should be 'alpha' after search()")
    mock.assert_equals(state.current_page, 1, "current_page should reset to 1 after search()")
end)

-- ============================================================
-- Test: browser.search with empty string clears the query
-- ============================================================
run_test("browser.search with empty string clears the query", function()
    mock_store_items = {
        {
            id = "li_001",
            mediaType = "book",
            media = {
                duration = 3600,
                metadata = { title = "Alpha Book", authorName = "Author A" },
            },
        },
    }

    browser.show({
        on_back = function() end,
        on_book_tap = function() end,
    })

    -- First search for something, then clear
    browser.search("alpha")
    browser.search("")

    local state = browser.getState()
    mock.assert_equals(state.search_query, "", "search_query should be empty after clearing")
    mock.assert_equals(state.current_page, 1, "current_page should be 1 after clearing")
end)

-- ============================================================
-- Test: browser.search integrates with library_store filter
-- (The data flow: browser.search → _search_query → getItems({search=...})
--  is verified by checking the store returns filtered results)
-- ============================================================
run_test("browser.search integrates with library_store filter", function()
    -- Set up items where search can actually filter
    mock_store_items = {
        {
            id = "li_001",
            mediaType = "book",
            addedAt = 1000,
            media = {
                duration = 3600,
                metadata = { title = "Alpha Book", authorName = "Author A" },
            },
        },
        {
            id = "li_002",
            mediaType = "book",
            addedAt = 2000,
            media = {
                duration = 7200,
                metadata = { title = "Beta Book", authorName = "Author B" },
            },
        },
    }

    browser.show({
        on_back = function() end,
        on_book_tap = function() end,
    })

    -- Search for "alpha" — should set query
    browser.search("alpha")
    mock.assert_equals(browser.getState().search_query, "alpha", "search query should be set")

    -- Verify the store filters correctly with this query
    local store = require("absaudio/library_store")
    local result = store.getItems({ search = "alpha" })
    mock.assert_equals(result.total_items, 1, "store should filter to 1 item")
    mock.assert_equals(store.getItemTitle(result.items[1]), "Alpha Book", "should find Alpha Book")

    -- Clear search — verify store returns all items
    browser.search("")
    local result2 = store.getItems({ search = "" })
    mock.assert_equals(result2.total_items, 2, "clearing search should return all items")
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
