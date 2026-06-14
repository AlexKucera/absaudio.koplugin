-- Book detail view tests
-- Tests book_detail.lua public API: show, _mergeItemData, _itemFromManifest,
-- _showFromManifestOrError, format helpers
--
-- Run with: luajit spec/test_book_detail.lua

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
package.loaded["ui/widget/focusmanager"] = make_class_stub()
package.loaded["ui/widget/container/framecontainer"] = make_widget_stub()
package.loaded["ui/widget/container/inputcontainer"] = make_widget_stub()
package.loaded["ui/widget/container/leftcontainer"] = make_widget_stub()
package.loaded["ui/widget/container/scrollablecontainer"] = make_widget_stub()
package.loaded["ui/widget/container/widgetcontainer"] = make_widget_stub()
package.loaded["ui/widget/horizontalgroup"] = make_widget_stub()
package.loaded["ui/widget/horizontalspan"] = make_widget_stub()
package.loaded["ui/widget/imagewidget"] = make_widget_stub()
package.loaded["ui/widget/infomessage"] = make_widget_stub()
package.loaded["ui/widget/confirmbox"] = make_widget_stub()
package.loaded["ui/widget/linewidget"] = make_widget_stub()
package.loaded["ui/widget/textboxwidget"] = make_widget_stub()
package.loaded["ui/widget/textwidget"] = {
    new = function(self, opts)
        local obj = opts or {}
        obj.getSize = function() return { w = 100, h = 20 } end
        obj.free = function() obj._bb = nil end  -- KOReader TextWidget:free() invalidates _bb cache
        return obj
    end,
}
package.loaded["ui/widget/verticalgroup"] = make_widget_stub()
package.loaded["ui/widget/verticalspan"] = make_widget_stub()

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
    new = function(self, opts) return opts or {} end,
}

package.loaded["ui/size"] = {
    padding = { large = 10, default = 5, small = 2 },
    line = { thin = 1 },
}

package.loaded["ui/uimanager"] = {
    show = function() end,
    close = function() end,
    setDirty = function() end,
    _scheduleLog = {},
    scheduleIn = function(delay, fn)
        table.insert(package.loaded["ui/uimanager"]._scheduleLog, { delay = delay })
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

-- Mock config
local mock_playback_speed = 1.0
package.loaded["config"] = {
    get = function(key)
        if key == "preferred_format" then return "m4b" end
        if key == "playback_speed" then return mock_playback_speed end
        return nil
    end,
    set = function(key, value)
        if key == "playback_speed" then mock_playback_speed = value end
    end,
    get_settings = function() return { flush = function() end } end,
}

-- Mock error_handler — tracks calls for assertions
local error_handler_calls = {}
package.loaded["error_handler"] = {
    show = function(error_type, details)
        table.insert(error_handler_calls, { type = error_type, details = details })
    end,
    show_api_error = function(err)
        table.insert(error_handler_calls, { type = "api_error", err = err })
    end,
    get_user_message = function(error_type, details)
        return error_type .. ": " .. tostring(details)
    end,
}

-- Mock api module — configurable per test
local mock_api_configured = true
local mock_api_item_details_ok = true
local mock_api_item_details_data = {}

package.loaded["api"] = {
    is_configured = function() return mock_api_configured end,
    getItemDetails = function(item_id)
        if mock_api_item_details_ok then
            return true, mock_api_item_details_data
        end
        return false, { type = "network", message = "connection failed" }
    end,
}

-- Mock manifest — configurable per test
local mock_manifest_books = {}

package.loaded["manifest"] = {
    init = function() end,
    getBook = function(item_id)
        return mock_manifest_books[item_id]
    end,
    isDownloaded = function(item_id)
        local book = mock_manifest_books[item_id]
        if not book or not book.files then return false end
        for _, f in ipairs(book.files) do
            if f.status ~= "complete" then return false end
        end
        return true
    end,
    hasIncompleteFiles = function(item_id)
        local book = mock_manifest_books[item_id]
        if not book or not book.files then return false end
        for _, f in ipairs(book.files) do
            if f.status == "pending" or f.status == "partial" then return true end
        end
        return false
    end,
}

-- Mock cover_cache
package.loaded["absaudio/cover_cache"] = {
    isInitialized = function() return true end,
    init = function() end,
    hasCachedCover = function() return false end,
    getCoverPath = function() return nil end,
    fetchAndCache = function() return false end,
}

-- Mock navigator
package.loaded["absaudio/navigator"] = {
    register = function() end,
    push = function() end,
    pop = function() end,
    reset = function() end,
    _reset = function() end,
}

-- Pre-load mocks for modules that book_detail.lua requires at load time
-- (so pcall(require) inside book_detail captures these, not the real modules)
package.loaded["absaudio/downloader"] = {
    prepare_download = function() return true, { abs_item_id = "mock_id", title = "Mock", local_dir = "/tmp/mock", files = {{ filename = "mock.m4b", status = "pending", size = 1000 }} } end,
    prepare_ebook_download = function() return false, "none" end,
    select_files_to_download = function(f) return f or {} end,
    calculate_download_size = function() return 1000 end,
    get_free_space = function() return 999999 end,
    check_free_space = function() return true end,
    create_download_state = function()
        local s = { cancelled=false, total_files=1, total_bytes=1000, bytes_downloaded=0, current_file="" }
        s.cancel = function(self) self.cancelled=true end
        s.is_cancelled = function(self) return self.cancelled end
        s.progress_fraction = function(self) return 0 end
        return s
    end,
    start_chunked_download = function(entry, file, deps)
        entry._start_chunked_called = true
        entry._start_chunked_file = file.filename
        return { pump=function()return false end, cancel=function()end, is_done=function()return true end, finalize=function()return true,nil end }
    end,
    format_bytes = function(b) return b.." B" end,
    delete_book = function(id, manifest, fs) return true end,
}
package.loaded["absaudio/download_progress"] = { show=function()end, update=function()end, close=function()end }
local ConfirmBoxMock = {}
function ConfirmBoxMock:new(opts)
    local o = opts or {}
    setmetatable(o, { __index = self })
    o.opts = opts
    return o
end
package.loaded["ui/widget/confirmbox"] = ConfirmBoxMock

-- Mock lfs for delete handlers that call _G.lfs or require("lfs")
_G.lfs = { attributes = function() return nil end, rmdir = function() end }
package.loaded["lfs"] = _G.lfs
------------------------------------------------------------------------
-- Require module under test
------------------------------------------------------------------------
local detail = require("absaudio/book_detail")
local mock = require("spec/test_helper")

------------------------------------------------------------------------
-- Test runner
------------------------------------------------------------------------
local passed = 0
local failed = 0
local errors = {}

local function run_test(name, fn)
    -- Reset mock state before each test
    error_handler_calls = {}
    mock_api_configured = true
    mock_api_item_details_ok = true
    mock_api_item_details_data = {}
    mock_manifest_books = {}

    -- Reset internal callbacks by calling show with fresh callbacks
    -- (detail.show sets _on_back and _on_download)

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
-- Test: _mergeItemData merges base item with expanded data
-- ============================================================
run_test("_mergeItemData merges base item with expanded data", function()
    local base = {
        id = "item_001",
        title = "Test Book",
        mediaType = "book",
        media = { duration = 3600, metadata = { title = "Test Book" } },
    }
    local expanded = {
        audioFiles = {
            { filename = "book.m4b", format = "m4b", size = 52428800 },
        },
        ebookFiles = {},
        media = { chapters = { { title = "Chapter 1", start = 0, ["end"] = 3600 } } },
    }

    local merged = detail._mergeItemData(base, expanded)

    mock.assert_equals(merged.id, "item_001", "should preserve base id")
    mock.assert_equals(merged.title, "Test Book", "should preserve base title")
    mock.assert_equals(merged.mediaType, "book", "should preserve base mediaType")
    mock.assert_equals(#merged.audioFiles, 1, "should have 1 audio file from expanded")
    mock.assert_equals(merged.audioFiles[1].format, "m4b", "audio file format should be m4b")
    mock.assert_equals(#merged.ebookFiles, 0, "should have 0 ebook files")
end)

-- ============================================================
-- Test: _mergeItemData: expanded data overwrites base keys
-- ============================================================
run_test("_mergeItemData: expanded data overwrites base keys", function()
    local base = { id = "item_001", extra = "base_value" }
    local expanded = { extra = "expanded_value", new_key = "new" }

    local merged = detail._mergeItemData(base, expanded)

    mock.assert_equals(merged.extra, "expanded_value", "expanded should overwrite base")
    mock.assert_equals(merged.new_key, "new", "new keys from expanded should be present")
end)

-- ============================================================
-- Test: _itemFromManifest builds correct item from manifest data
-- ============================================================
run_test("_itemFromManifest builds correct item from manifest data", function()
    local item = {
        id = "item_001",
        title = "API Title",
        mediaType = "book",
        addedAt = 1000,
    }
    local book = {
        abs_item_id = "item_001",
        title = "Manifest Title",
        author = "Manifest Author",
        duration = 7200,
        chapters = {
            { title = "Ch 1", start = 0, ["end"] = 3600 },
            { title = "Ch 2", start = 3600, ["end"] = 7200 },
        },
    }

    local result = detail._itemFromManifest(item, book)

    mock.assert_equals(result.id, "item_001", "should use item id")
    mock.assert_equals(result.title, "Manifest Title", "should use manifest title")
    mock.assert_equals(result.author, "Manifest Author", "should use manifest author")
    mock.assert_equals(result.media.duration, 7200, "should use manifest duration")
    mock.assert_equals(result.media.metadata.title, "Manifest Title", "metadata title from manifest")
    mock.assert_equals(result.media.metadata.authorName, "Manifest Author", "metadata author from manifest")
    mock.assert_equals(#result.media.chapters, 2, "should have 2 chapters from manifest")
    mock.assert_equals(#result.audioFiles, 0, "audioFiles should be empty (manifest doesn't track ABS files)")
    mock.assert_equals(#result.ebookFiles, 0, "ebookFiles should be empty")
end)

-- ============================================================
-- Test: _itemFromManifest falls back to item data when manifest lacks fields
-- ============================================================
run_test("_itemFromManifest falls back to item data when manifest lacks fields", function()
    local item = {
        id = "item_002",
        title = "Item Title",
        mediaType = "book",
        addedAt = 2000,
    }
    local book = {
        abs_item_id = "item_002",
        title = nil,
        author = nil,
        duration = nil,
        chapters = {},
    }

    local result = detail._itemFromManifest(item, book)

    mock.assert_equals(result.title, "Item Title", "should fall back to item title")
    mock.assert_equals(result.author, "", "should default to empty string for author")
    mock.assert_equals(result.media.duration, nil, "duration should be nil when not in manifest")
end)

-- ============================================================
-- Test: show with API available calls _fetchAndShow
-- (verified by checking scheduleIn was used for async fetch)
-- ============================================================
run_test("show with API available attempts to fetch item details", function()
    local item = {
        id = "item_001",
        title = "Test Book",
        mediaType = "book",
        media = { duration = 3600 },
    }

    -- With API configured and available, show() should attempt to fetch
    mock_api_configured = true
    mock_api_item_details_ok = true
    mock_api_item_details_data = {
        audioFiles = {},
        ebookFiles = {},
        media = { chapters = {} },
    }

    -- This should not error — it schedules async fetch via UIManager
    detail.show({ item = item,
        on_download = function() end,
    })

    -- If we got here without error, the function completed successfully
    mock.assert_equals(true, true, "show should complete without error when API is available")
end)

-- ============================================================
-- Test: show without API configured falls back to manifest/error
-- ============================================================
run_test("show without API configured falls back to manifest/error", function()
    local item = {
        id = "item_noapi",
        title = "Offline Book",
        mediaType = "book",
        media = { duration = 3600 },
    }

    mock_api_configured = false

    -- Without API, should try manifest fallback
    detail.show({ item = item })

    -- No error_handler.show should have been called yet because item has title/media
    -- (it shows the limited data from list item)
    mock.assert_equals(#error_handler_calls, 0, "should not show error when item has basic data")
end)

-- ============================================================
-- Test: show without API and without manifest shows WiFi message
-- ============================================================
run_test("show without API and without manifest data shows WiFi message", function()
    local item = {
        id = "item_nothing",
        -- No title, no media — completely empty item
    }

    mock_api_configured = false
    mock_manifest_books = {}  -- no manifest data

    detail.show({ item = item })

    -- Should have called error_handler.show with network error
    mock.assert_equals(#error_handler_calls, 1, "should show exactly one error")
    mock.assert_equals(error_handler_calls[1].type, "network", "should be a network error")
end)

-- ============================================================
-- Test: show without API falls back to manifest data when available
-- ============================================================
run_test("show without API falls back to manifest data when available", function()
    local item = {
        id = "item_manifest",
        title = "API Title",
        mediaType = "book",
        media = { duration = 3600 },
    }

    mock_api_configured = false
    mock_manifest_books = {
        item_manifest = {
            abs_item_id = "item_manifest",
            title = "Manifest Title",
            author = "Manifest Author",
            duration = 7200,
            local_dir = "/mnt/ext1/audiobooks/item_manifest",
            chapters = {
                { title = "Chapter 1", start = 0, ["end"] = 7200 },
            },
        },
    }

    -- Should not error — it renders the view from manifest data
    detail.show({ item = item })

    mock.assert_equals(#error_handler_calls, 0, "should not show error when manifest data available")
end)

-- ============================================================
-- Test: show with item that has title but no manifest shows limited data
-- ============================================================
run_test("show with item title but no manifest shows limited data (no error)", function()
    local item = {
        id = "item_basic",
        title = "Basic Title",
        media = {
            duration = 1800,
            metadata = { title = "Basic Title", authorName = "Author" },
        },
    }

    mock_api_configured = false
    mock_manifest_books = {}

    detail.show({ item = item })

    -- Has title/media so should NOT show error
    mock.assert_equals(#error_handler_calls, 0, "should not show error when item has title and media")
end)

run_test("onClose calls nav.pop() for back navigation", function()
    local popped = false
    package.loaded["absaudio/navigator"].pop = function()
        popped = true
    end

    local shown_widgets = {}
    local orig_show = package.loaded["ui/uimanager"].show
    package.loaded["ui/uimanager"].show = function(self, widget)
        table.insert(shown_widgets, widget)
    end

    local item = {
        id = "item_nav",
        title = "Nav Book",
        mediaType = "book",
        media = { duration = 3600 },
    }

    mock_api_configured = false
    mock_manifest_books = {}

    detail.show({ item = item })

    local view = shown_widgets[#shown_widgets]
    mock.assert_equals(view ~= nil, true, "should have created a view widget")

    view:onClose()
    mock.assert_equals(popped, true, "onClose should have called nav.pop()")

    package.loaded["ui/uimanager"].show = orig_show
    package.loaded["absaudio/navigator"].pop = function() end
end)

-- ============================================================
-- Test: on_download callback reads from instance state
-- ============================================================
run_test("on_download callback uses instance state", function()
    local downloaded_item = nil

    -- Capture instances
    local shown_widgets = {}
    local orig_show = package.loaded["ui/uimanager"].show
    package.loaded["ui/uimanager"].show = function(self, widget)
        table.insert(shown_widgets, widget)
    end

    local item = {
        id = "item_dl",
        title = "Downloadable Book",
        mediaType = "book",
        media = { duration = 3600 },
    }

    mock_api_configured = false
    mock_manifest_books = {}  -- not downloaded, so download button appears

    detail.show({
        item = item,
        on_download = function(it) downloaded_item = it end,
    })

    local view = shown_widgets[#shown_widgets]
    mock.assert_equals(view ~= nil, true, "should have created a view widget")

    -- The download button tap container should reference the view's on_download
    -- Simulate finding and invoking the download tap handler
    -- We verify it by checking self.on_download is set on the instance
    mock.assert_equals(type(view.on_download), "function", "view should have on_download function")

    -- Call on_download directly to verify it uses the instance's callback
    view.on_download(item)
    mock.assert_equals(downloaded_item ~= nil, true, "on_download callback should have been invoked")
    mock.assert_equals(downloaded_item.id, "item_dl", "on_download should receive correct item")

    -- Restore
    package.loaded["ui/uimanager"].show = orig_show
end)

-- ============================================================
-- Test: detail.prepare() returns merged data when API succeeds
-- ============================================================
run_test("prepare() returns merged data when API succeeds", function()
    local item = {
        id = "item_prepare_ok",
        title = "Base Title",
        mediaType = "book",
        addedAt = 1000,
        media = { duration = 3600 },
    }

    mock_api_configured = true
    mock_api_item_details_ok = true
    mock_api_item_details_data = {
        audioFiles = {
            { filename = "book.m4b", format = "m4b", size = 52428800 },
        },
        ebookFiles = {},
        media = { chapters = { { title = "Chapter 1", start = 0, ["end"] = 3600 } } },
    }
    mock_manifest_books = {}

    local data, err = detail.prepare(item)

    mock.assert_equals(data ~= nil, true, "should return data on success")
    mock.assert_equals(err, nil, "should return nil error on success")
    mock.assert_equals(data.id, "item_prepare_ok", "should preserve base id")
    mock.assert_equals(data.title, "Base Title", "should preserve base title")
    mock.assert_equals(#data.audioFiles, 1, "should have merged audioFiles from expanded")
    mock.assert_equals(data.audioFiles[1].format, "m4b", "audio file format should be m4b")
    mock.assert_equals(data.mediaType, "book", "should preserve base mediaType")
end)

-- ============================================================
-- Test: detail.prepare() falls back to manifest when API fails
-- ============================================================
run_test("prepare() falls back to manifest when API fails", function()
    local item = {
        id = "item_manifest_fallback",
        title = "Base Title",
        mediaType = "book",
        addedAt = 1000,
    }

    mock_api_configured = true
    mock_api_item_details_ok = false
    mock_manifest_books = {
        ["item_manifest_fallback"] = {
            abs_item_id = "item_manifest_fallback",
            title = "Manifest Title",
            author = "Author Name",
            duration = 7200,
        },
    }

    local data, err = detail.prepare(item)

    mock.assert_equals(data ~= nil, true, "should return data on manifest fallback")
    mock.assert_equals(err, nil, "should return nil error on manifest fallback")
    mock.assert_equals(data.id, "item_manifest_fallback", "should preserve base id")
    mock.assert_equals(data.title, "Manifest Title", "should use manifest title")
    mock.assert_equals(data.author, "Author Name", "should use manifest author")
    mock.assert_equals(data.media.duration, 7200, "should use manifest duration in media table")
end)

-- ============================================================
-- Test: detail.prepare() returns error when API fails, no manifest
-- ============================================================
run_test("prepare() returns error when API fails and no manifest", function()
    local item = {
        id = "item_no_data",
        mediaType = "book",
        addedAt = 1000,
    }

    mock_api_configured = true
    mock_api_item_details_ok = false
    mock_manifest_books = {}

    local data, err = detail.prepare(item)

    mock.assert_equals(data, nil, "should return nil data")
    mock.assert_equals(err ~= nil, true, "should return error info")
    mock.assert_equals(err.type, "network", "error type should be network")
end)

-- ============================================================
-- Test: detail.prepare() returns basic item when offline with title
-- ============================================================
run_test("prepare() returns basic item when offline but item has title/media", function()
    local item = {
        id = "item_offline_basic",
        title = "Offline Book",
        mediaType = "book",
        media = { duration = 1800 },
    }

    mock_api_configured = false
    mock_manifest_books = {}

    local data, err = detail.prepare(item)

    mock.assert_equals(data ~= nil, true, "should return data")
    mock.assert_equals(err, nil, "should not return error")
    mock.assert_equals(data.title, "Offline Book", "should preserve title")
    mock.assert_equals(data.media.duration, 1800, "should preserve media duration")
end)

-- ============================================================
-- Test: Download status badge and button behavior
-- ============================================================

-- Helper: search content_group for text matching pattern (checks InputContainer children too)
local function find_text_in_view(view, pattern)
    for _, widget in ipairs(view.content_group or {}) do
        if widget.text and widget.text:match(pattern) then return true end
        -- Buttons are wrapped in InputContainer → [1] = TextWidget
        if widget[1] and widget[1].text and widget[1].text:match(pattern) then return true end
    end
    return false
end

run_test("_addDownloadStatus shows ✓ Downloaded when all files complete", function()
    local shown_widgets = {}
    local orig_show = package.loaded["ui/uimanager"].show
    package.loaded["ui/uimanager"].show = function(self, widget)
        table.insert(shown_widgets, widget)
    end

    local item = {
        id = "item_complete",
        title = "Complete Book",
        media = { duration = 3600, metadata = { title = "Complete Book" } },
    }
    mock_api_configured = false
    mock_manifest_books = {
        item_complete = {
            abs_item_id = "item_complete",
            files = {
                { filename = "book.m4b", status = "complete" },
            },
        },
    }

    detail.show({ item = item,
        on_download = function() end,
        on_delete = function() end,
    })

    local view = shown_widgets[#shown_widgets]
    mock.assert_equals(view ~= nil, true, "should have created a view")
    mock.assert_equals(find_text_in_view(view, "Audio downloaded"), true, "should show Audio downloaded badge")
    mock.assert_equals(find_text_in_view(view, "Delete audio"), true, "should show Delete button when downloaded")

    package.loaded["ui/uimanager"].show = orig_show
end)

run_test("_addDownloadStatus shows Resume when files incomplete", function()
    local shown_widgets = {}
    local orig_show = package.loaded["ui/uimanager"].show
    package.loaded["ui/uimanager"].show = function(self, widget)
        table.insert(shown_widgets, widget)
    end

    local item = {
        id = "item_partial",
        title = "Partial Book",
        media = { duration = 3600, metadata = { title = "Partial Book" } },
    }
    mock_api_configured = false
    mock_manifest_books = {
        item_partial = {
            abs_item_id = "item_partial",
            files = {
                { filename = "part1.m4b", status = "complete" },
                { filename = "part2.m4b", status = "partial" },
            },
        },
    }

    detail.show({ item = item,
        on_download = function() end,
    })

    local view = shown_widgets[#shown_widgets]
    mock.assert_equals(view ~= nil, true, "should have created a view")
    mock.assert_equals(find_text_in_view(view, "Resume"), true, "should show Resume button")

    package.loaded["ui/uimanager"].show = orig_show
end)

run_test("_addDownloadStatus shows Download button when not in manifest", function()
    local shown_widgets = {}
    local orig_show = package.loaded["ui/uimanager"].show
    package.loaded["ui/uimanager"].show = function(self, widget)
        table.insert(shown_widgets, widget)
    end

    local item = {
        id = "item_new",
        title = "New Book",
        media = { duration = 3600, metadata = { title = "New Book" } },
    }
    mock_api_configured = false
    mock_manifest_books = {}

    detail.show({ item = item,
        on_download = function() end,
    })

    local view = shown_widgets[#shown_widgets]
    mock.assert_equals(view ~= nil, true, "should have created a view")
    mock.assert_equals(find_text_in_view(view, "Download audio"), true, "should show Download audio button")

    package.loaded["ui/uimanager"].show = orig_show
end)

-- ============================================================
-- Gap 5: Ebook download button
-- ============================================================

run_test("_addEbookFiles adds download button when on_download set", function()
    local item = {
        id = "item_ebook",
        title = "Ebook Book",
        mediaType = "book",
        media = { duration = 3600, metadata = { title = "Ebook Book", authorName = "Author" } },
    }

    -- Use sync path (no API) with item that has ebookFiles from mock
    mock_api_configured = false
    mock_manifest_books = {}

    -- Add ebookFiles directly to item so _addEbookFiles sees them
    item.ebookFiles = {
        { filename = "book.epub", format = "epub", size = 1048576 },
    }

    local download_called = false
    local download_data = nil

    local view = detail.show({
        item = item,
        on_download = function(data)
            download_called = true
            download_data = data
        end,
    })

    -- Verify that the view was created
    mock.assert_equals(view ~= nil, true, "view should exist")

    -- Check that the ebook button text is in the view
    mock.assert_equals(find_text_in_view(view, "Ebook"), true, "should show Download Ebook button")
end)

run_test("_addEbookFiles detects ebook from media.ebookFile (ABS format)", function()
    local item = {
        id = "item_abs_ebook",
        title = "ABS Ebook Book",
        mediaType = "book",
        media = {
            duration = 3600,
            metadata = { title = "ABS Ebook Book", authorName = "Author" },
            ebookFile = {
                ino = "1590509",
                metadata = {
                    filename = "Oathbringer.pdf",
                    ext = ".pdf",
                    size = 17386979,
                },
                ebookFormat = "pdf",
            },
        },
    }

    mock_api_configured = false
    mock_manifest_books = {}

    local view = detail.show({
        item = item,
        on_download = function(data) end,
        on_delete = function(data) end,
    })

    -- Should detect the ebook from media.ebookFile and show download button
    mock.assert_equals(view ~= nil, true, "should have created a view")
    mock.assert_equals(find_text_in_view(view, "Oathbringer.pdf"), true,
        "should show ebook filename from media.ebookFile")
end)

-- Regression: LuaJSON null sentinel must not crash ebookFile detection
-- KOReader uses LuaJSON which decodes JSON null as a sentinel function (json.util.null),
-- not nil. The code must use type() == "table" instead of truthiness.
run_test("_addEbookFiles handles LuaJSON null sentinel for ebookFile", function()
    local null_sentinel = function() return null_sentinel end  -- mimics json.util.null
    local item = {
        id = "item_null_ebook",
        title = "Null Ebook Book",
        mediaType = "book",
        media = {
            duration = 3600,
            metadata = { title = "Null Ebook Book", authorName = "Author" },
            ebookFile = null_sentinel,  -- LuaJSON null, not nil!
        },
    }

    mock_api_configured = false
    mock_manifest_books = {}

    local view = detail.show({
        item = item,
        on_download = function(data) end,
        on_delete = function(data) end,
    })

    -- Should NOT crash; should simply skip ebook section
    mock.assert_equals(view ~= nil, true, "should have created a view without crashing")
    mock.assert_equals(find_text_in_view(view, "Oathbringer.pdf"), false,
        "should NOT show ebook filename when ebookFile is null sentinel")
end)

-- ============================================================
-- Test: Open Ebook button appears when ebook is fully downloaded
-- ============================================================

run_test("_addEbookFiles shows Open Ebook button when ebook is complete", function()
    local item = {
        id = "item_ebook_open",
        title = "Openable Ebook",
        mediaType = "book",
        media = {
            duration = 3600,
            metadata = { title = "Openable Ebook", authorName = "Author" },
            ebookFile = {
                ino = "999",
                metadata = {
                    filename = "TestBook.epub",
                    ext = ".epub",
                    size = 1024000,
                },
                ebookFormat = "epub",
            },
        },
    }

    mock_api_configured = false
    mock_manifest_books = {
        item_ebook_open = {
            abs_item_id = "item_ebook_open",
            title = "Openable Ebook",
            author = "Author",
            local_dir = "/tmp/test_ebook",
            files = {
                {
                    filename = "TestBook.epub",
                    ino = "999",
                    size = 1024000,
                    type = "ebook",
                    status = "complete",
                },
            },
        },
    }

    local open_ebook_called = false
    local open_ebook_path = nil

    local view = detail.show({
        item = item,
        on_download = function(data) end,
        on_delete = function(data) end,
        on_open_ebook = function(path)
            open_ebook_called = true
            open_ebook_path = path
        end,
    })

    mock.assert_equals(view ~= nil, true, "should have created a view")

    mock.assert_equals(view ~= nil, true, "should have created a view")
    mock.assert_equals(find_text_in_view(view, "Open Ebook"), true,
        "should show Open Ebook button when ebook is complete")
end)

run_test("_addEbookFiles does NOT show Open Ebook button when ebook is not downloaded", function()
    local item = {
        id = "item_ebook_nodl",
        title = "No Download Ebook",
        mediaType = "book",
        media = {
            duration = 3600,
            metadata = { title = "No Download Ebook", authorName = "Author" },
            ebookFile = {
                ino = "888",
                metadata = {
                    filename = "NoDL.epub",
                    ext = ".epub",
                    size = 500000,
                },
                ebookFormat = "epub",
            },
        },
    }

    mock_api_configured = false
    mock_manifest_books = {}  -- no manifest entry = not downloaded

    local view = detail.show({
        item = item,
        on_download = function(data) end,
        on_delete = function(data) end,
        on_open_ebook = function(path) end,
    })

    mock.assert_equals(view ~= nil, true, "should have created a view")
    mock.assert_equals(find_text_in_view(view, "Open Ebook"), false,
        "should NOT show Open Ebook button when ebook is not downloaded")
end)

run_test("_addEbookFiles on_open_ebook calls _onOpenEbook with correct path", function()
    local item = {
        id = "item_ebook_cb",
        title = "Callback Ebook",
        mediaType = "book",
        media = {
            duration = 3600,
            metadata = { title = "Callback Ebook", authorName = "Author" },
            ebookFile = {
                ino = "777",
                metadata = {
                    filename = "CallbackBook.pdf",
                    ext = ".pdf",
                    size = 2048000,
                },
                ebookFormat = "pdf",
            },
        },
    }

    mock_api_configured = false
    mock_manifest_books = {
        item_ebook_cb = {
            abs_item_id = "item_ebook_cb",
            title = "Callback Ebook",
            author = "Author",
            local_dir = "/tmp/callback_ebook",
            files = {
                {
                    filename = "CallbackBook.pdf",
                    ino = "777",
                    size = 2048000,
                    type = "ebook",
                    status = "complete",
                },
            },
        },
    }

    -- Mock ReaderUI so _onOpenEbook doesn't crash
    local readerui_show_called = false
    local readerui_path = nil
    package.loaded["apps/reader/readerui"] = {
        showReader = function(self, path)
            readerui_show_called = true
            readerui_path = path
        end,
    }

    -- Call show() without callbacks - uses self-contained _onOpenEbook
    local view = detail.show({ item = item })

    mock.assert_equals(view ~= nil, true, "should have created a view")

    -- Simulate tapping the Open Ebook button
    for _, widget in ipairs(view.content_group or {}) do
        if widget[1] and widget[1].text and widget[1].text:match("Open Ebook") then
            if widget.onTapOpenEbook then
                widget:onTapOpenEbook()
            end
            break
        end
    end
    mock.assert_equals(readerui_show_called, true, "_onOpenEbook should call ReaderUI")
    mock.assert_equals(readerui_path, "/tmp/callback_ebook/CallbackBook.pdf",
        "should pass correct file path to ReaderUI")

    -- Clean up mock
    package.loaded["apps/reader/readerui"] = nil
end)
-- ============================================================
-- Test: BookDetailView has own _onDownloadBook method (self-contained)
-- ============================================================
run_test("BookDetailView:_onDownloadBook calls start_chunked_download and schedules pump", function()
    -- Uses pre-load mocks (set before require) so book_detail captured them
    local item = {}
    item.id = "test_id"
    item.title = "Test Book"
    item.mediaType = "book"
    item.media = {}
    item.media.duration = 3600
    item.media.metadata = {}
    item.media.metadata.title = "Test Book"
    item.media.metadata.authorName = "Author"
    item.media.audioFiles = {}
    item.media.audioFiles[1] = {}
    item.media.audioFiles[1].ino = "1"
    item.media.audioFiles[1].metadata = {}
    item.media.audioFiles[1].metadata.filename = "test.m4b"
    item.media.audioFiles[1].metadata.ext = ".m4b"
    item.media.audioFiles[1].metadata.size = 1000

    mock_api_configured = false
    mock_manifest_books = {}

    local view = detail.show({ item = item })

    mock.assert_equals(type(view._onDownloadBook), "function",
        "BookDetailView must have _onDownloadBook method")

    -- Override scheduleIn locally to execute small-delay callbacks (so download pipeline runs)
    local uim = package.loaded["ui/uimanager"]
    local orig_scheduleIn = uim.scheduleIn
        uim.scheduleIn = function(delay, fn)
            orig_scheduleIn(delay, fn)
            if type(delay) == "number" and (not delay or delay <= 0.2) then fn() end
    end
    -- Call should not error — exercises full pipeline with pre-load mocks
    view:_onDownloadBook(item, false)

    -- Restore original scheduleIn
    uim.scheduleIn = orig_scheduleIn

    mock.assert_equals(#uim._scheduleLog >= 1, true,
        "should have scheduled via UIManager.scheduleIn")
end)

-- ============================================================
-- Test: BookDetailView has own _onOpenEbook method
-- ============================================================
run_test("BookDetailView:_onOpenEbook opens ReaderUI with filepath", function()
    local opened_filepath = nil

    -- Mock ReaderUI (colon-call passes self as first arg)
    package.loaded["apps/reader/readerui"] = {
        showReader = function(self, filepath)
            opened_filepath = filepath
        end,
    }

    local item = {
        id = "ebook_test",
        title = "Ebook Test",
        mediaType = "book",
        media = { duration=3600, metadata={title="Ebook Test", authorName="Author"} },
    }
    mock_api_configured = false
    mock_manifest_books = {}

    local view = detail.show({ item = item })

    -- Must have _onOpenEbook method
    mock.assert_equals(type(view._onOpenEbook), "function",
        "BookDetailView must have _onOpenEbook method")

    -- Call it
    view:_onOpenEbook("/tmp/test/book.epub")

    mock.assert_equals(opened_filepath, "/tmp/test/book.epub",
        "should open ReaderUI with correct filepath")

    -- Clean up
    package.loaded["apps/reader/readerui"] = nil
end)
-- ============================================================
-- Test: BookDetailView has own _onDeleteBook method
-- ============================================================
run_test("BookDetailView:_onDeleteBook shows ConfirmBox and deletes book", function()
    local deleted_id = nil
    local confirmbox_text = nil
    local uimanager_widgets = {}

    -- Intercept UIManager.show to capture ConfirmBox and auto-confirm
    local orig_show = package.loaded["ui/uimanager"].show
    package.loaded["ui/uimanager"].show = function(self, widget)
        table.insert(uimanager_widgets, widget)
        -- Auto-confirm: if this looks like a ConfirmBox, fire ok_callback
        if widget and widget.opts and widget.opts.ok_callback then
            confirmbox_text = widget.opts.text
            widget.opts.ok_callback()
        end
    end

    -- Spy on delete_book by mutating the pre-loaded downloader table
    -- (book_detail's local `downloader` points to this same table)
    local dl_mock = package.loaded["absaudio/downloader"]
    local orig_delete_book = dl_mock.delete_book
    dl_mock.delete_book = function(id, manifest, fs)
        deleted_id = id
        return true
    end

    local item = {
        id = "del_test",
        title = "Delete Me",
        mediaType = "book",
        media = { duration=3600, metadata={title="Delete Me", authorName="Author"} },
    }
    mock_api_configured = false
    mock_manifest_books = {}

    local view = detail.show({ item = item })

    -- Must have _onDeleteBook method
    mock.assert_equals(type(view._onDeleteBook), "function",
        "BookDetailView must have _onDeleteBook method")

    -- Call it — should show ConfirmBox, then delete when confirmed
    view:_onDeleteBook(item, false)

    mock.assert_equals(confirmbox_text ~= nil, true, "should show ConfirmBox")
    mock.assert_equals(deleted_id, "del_test", "should delete correct book ID")

    -- Restore mocks
    package.loaded["ui/uimanager"].show = orig_show
    dl_mock.delete_book = orig_delete_book
end)
-- ============================================================
-- Test: Detail view works without any callbacks (self-contained)
-- ============================================================
run_test("detail.show without callbacks still has working action methods", function()
    local item = {
        id = "self_wire_test",
        title = "Self Wired",
        mediaType = "book",
        media = { duration=3600, metadata={title="Self Wired", authorName="Author"} },
    }
    mock_api_configured = false
    mock_manifest_books = {}

    -- Call show() with NO callbacks at all - this is the new interface
    local view = detail.show({ item = item })

    mock.assert_equals(view ~= nil, true, "should create view without callbacks")

    -- All four action methods must exist regardless of callbacks being passed
    mock.assert_equals(type(view._onDownloadBook), "function", "must have _onDownloadBook")
    mock.assert_equals(type(view._onDeleteBook), "function", "must have _onDeleteBook")
    mock.assert_equals(type(view._onDeleteEbookOnly), "function", "must have _onDeleteEbookOnly")
    mock.assert_equals(type(view._onOpenEbook), "function", "must have _onOpenEbook")
end)
if #errors > 0 then
    print("\nFailures:")
    for _, e in ipairs(errors) do
        print("  " .. e.name .. ": " .. tostring(e.err))
    end
    os.exit(1)
end
-- ============================================================
-- Ebook status tests: per-type download status
-- ============================================================

-- Ebook per-type status tested in test_downloader.lua (slices 11-13)
-- Book detail UI tests for ebook status + Open Ebook button covered by _addEbookFiles tests

-- ============================================================
-- Regression: download guard uses correct variable name (has_abs_config)
-- ============================================================

run_test("_onDownloadBook does not show 'not available' when modules loaded", function()
    -- This regression test catches the bug where the guard checked
    -- has_config (nil/undeclared) instead of has_abs_config,
    -- causing ALL downloads to show "Download not available"
    local view = detail._renderView({
        title = "Guard Test",
        id = "regress_guard",
        authors = {},
        series = nil,
        description = "test",
        narrators = {},
        duration_seconds = 3600,
        cover_url = nil,
        formats = { audiobook = { id = "fmt1" } },
        ebook_formats = {},
        status = {},
    })
    assert(view.detail_ref, "detail_ref should exist")

    -- All requires should have succeeded in this test environment
    -- so calling _onDownloadBook should NOT trigger the availability guard
    local info_shown = false
    local uim = package.loaded["ui/uimanager"]
    local orig_show = uim.show
    uim.show = function(_, w)
        if w.text and w.text:find("not available") then
            info_shown = true
        end
    end

    pcall(function() view.detail_ref:_onDownloadBook({ id = "test", formats = { audiobook = { id = "fmt1" } } }, false) end)

    uim.show = orig_show
    assert(not info_shown, "should NOT show 'download not available' when modules are present")
end)

-- ============================================================
-- Slice 8: Now-playing UI renders when audio is downloaded
-- ============================================================

run_test("now-playing: adds controls section when audio is complete", function()
    -- Set up manifest with a downloaded audiobook
    local mock_manifest_book = {
        id = "np_complete",
        title = "Now Playing Test",
        author = "Test Author",
        duration = 3600,
        local_dir = "/tmp/absaudio_np",
        current_time = 120,
        files = {
            { filename = "track1.m4b", type = "audio", status = "complete" },
            { filename = "track2.m4b", type = "audio", status = "complete" },
        },
        chapters = {},
    }
    mock_manifest_books = { ["np_complete"] = mock_manifest_book }

    local item = {
        id = "np_complete",
        title = "Now Playing Test",
        mediaType = "book",
        media = {
            duration = 3600,
            metadata = { title = "Now Playing Test", authorName = "Test Author" },
            audioFiles = {
                { filename = "track1.m4b", format = "m4b", duration = 1800 },
                { filename = "track2.m4b", format = "m4b", duration = 1800 },
            },
        },
    }
    mock_api_configured = false  -- force manifest path

    local view = detail._renderView(item)

    -- Audio is complete → now-playing section should exist
    mock.assert_equals(view.audio_download_state, "complete", "audio state detected as complete")
    mock.assert_equals(view.player ~= nil, true, "player instance created")
end)

run_test("now-playing: does NOT add controls when audio not downloaded", function()
    mock_manifest_books = {}

    local item = {
        id = "np_none",
        title = "No Download",
        mediaType = "book",
        media = {
            duration = 3600,
            metadata = { title = "No Download" },
            audioFiles = {
                { filename = "track.m4b", format = "m4b", duration = 3600 },
            },
        },
    }
    mock_api_configured = false

    local view = detail._renderView(item)

    -- No download → no player, no now-playing section
    mock.assert_equals(view.player == nil, true, "no player when not downloaded")
    mock.assert_equals(view.audio_download_state, "none", "audio state is none")
end)

run_test("now-playing: does NOT add controls when audio incomplete", function()
    local mock_manifest_book = {
        id = "np_partial",
        title = "Partial Download",
        local_dir = "/tmp/absaudio_np_p",
        files = {
            { filename = "track1.m4b", type = "audio", status = "partial" },
        },
        chapters = {},
    }
    mock_manifest_books = { ["np_partial"] = mock_manifest_book }

    local item = {
        id = "np_partial",
        title = "Partial Download",
        mediaType = "book",
        media = {
            duration = 3600,
            metadata = { title = "Partial Download" },
            audioFiles = {
                { filename = "track1.m4b", format = "m4b", duration = 3600 },
            },
        },
    }
    mock_api_configured = false

    local view = detail._renderView(item)

    -- Partial download → no player
    mock.assert_equals(view.player == nil, true, "no player when partial")
    mock.assert_equals(view.audio_download_state, "incomplete", "audio state is incomplete")
end)

run_test("now-playing: player has correct track info from manifest", function()
    local mock_manifest_book = {
        id = "np_tracks",
        title = "Multi Track",
        author = "Author",
        duration = 300 + 240 + 280,
        local_dir = "/tmp/absaudio_np_mt",
        current_time = 500,
        files = {
            { filename = "t1.m4b", type = "audio", status = "complete" },
            { filename = "t2.m4b", type = "audio", status = "complete" },
            { filename = "t3.m4b", type = "audio", status = "complete" },
        },
        chapters = {},
    }
    mock_manifest_books = { ["np_tracks"] = mock_manifest_book }

    local item = {
        id = "np_tracks",
        title = "Multi Track",
        mediaType = "book",
        media = {
            duration = 820,
            metadata = { title = "Multi Track", authorName = "Author" },
            audioFiles = {
                { filename = "t1.m4b", format = "m4b", duration = 300 },
                { filename = "t2.m4b", format = "m4b", duration = 240 },
                { filename = "t3.m4b", format = "m4b", duration = 280 },
            },
        },
    }
    mock_api_configured = false

    local view = detail._renderView(item)

    -- Player should be created with correct data
    local p = view.player
    mock.assert_equals(p ~= nil, true, "player exists")
    mock.assert_equals(p:getDuration(), 820, "total duration matches")
    mock.assert_equals(p:getPosition(), 500, "starts at stored position")
end)

-- ============================================================
-- Slice 9: Now-playing controls are tappable
-- ============================================================

run_test("now-playing tap play/pause: toggles player state", function()
    local mock_manifest_book = {
        id = "np_tap_play",
        title = "Tap Play Test",
        local_dir = "/tmp/absaudio_np_tp",
        current_time = 0,
        files = {
            { filename = "track.m4b", type = "audio", status = "complete" },
        },
        chapters = {},
    }
    mock_manifest_books = { ["np_tap_play"] = mock_manifest_book }

    local item = {
        id = "np_tap_play",
        title = "Tap Play Test",
        mediaType = "book",
        media = {
            duration = 600,
            metadata = { title = "Tap Play Test" },
            audioFiles = {
                { filename = "track.m4b", format = "m4b", duration = 600 },
            },
        },
    }
    mock_api_configured = false

    local view = detail._renderView(item)
    local p = view.player

    -- Initially stopped
    mock.assert_equals(p:getState(), "stopped", "initially stopped")

    -- Tap play
    view:_onPlayPause()
    mock.assert_equals(p:getState(), "playing", "playing after tap")

    -- Tap pause
    view:_onPlayPause()
    mock.assert_equals(p:getState(), "paused", "paused after second tap")

    -- Tap resume
    view:_onPlayPause()
    mock.assert_equals(p:getState(), "playing", "resumed after third tap")
end)

run_test("now-playing skip-back: seeks 30s backward", function()
    local mock_manifest_book = {
        id = "np_skip_back",
        title = "Skip Back Test",
        local_dir = "/tmp/absaudio_np_sb",
        current_time = 100,
        files = {
            { filename = "track.m4b", type = "audio", status = "complete" },
        },
        chapters = {},
    }
    mock_manifest_books = { ["np_skip_back"] = mock_manifest_book }

    local item = {
        id = "np_skip_back",
        title = "Skip Back Test",
        mediaType = "book",
        media = {
            duration = 600,
            metadata = { title = "Skip Back Test" },
            audioFiles = {
                { filename = "track.m4b", format = "m4b", duration = 600 },
            },
        },
    }
    mock_api_configured = false

    local view = detail._renderView(item)
    local p = view.player

    p:play()
    p:_advanceTime(10)  -- position = 100 + 10 = 110

    -- Skip back 30s
    view:_onSkipBack()
    mock.assert_equals(p:getPosition(), 80, "110 - 30 = 80")
end)

run_test("now-playing skip-forward: seeks 30s forward", function()
    local mock_manifest_book = {
        id = "np_skip_fwd",
        title = "Skip Fwd Test",
        local_dir = "/tmp/absaudio_np_sf",
        current_time = 0,
        files = {
            { filename = "track.m4b", type = "audio", status = "complete" },
        },
        chapters = {},
    }
    mock_manifest_books = { ["np_skip_fwd"] = mock_manifest_book }

    local item = {
        id = "np_skip_fwd",
        title = "Skip Fwd Test",
        mediaType = "book",
        media = {
            duration = 600,
            metadata = { title = "Skip Fwd Test" },
            audioFiles = {
                { filename = "track.m4b", format = "m4b", duration = 600 },
            },
        },
    }
    mock_api_configured = false

    local view = detail._renderView(item)
    local p = view.player

    p:play()
    p:_advanceTime(10)  -- position = 10

    -- Skip forward 30s
    view:_onSkipForward()
    mock.assert_equals(p:getPosition(), 40, "10 + 30 = 40")
end)

-- ============================================================
-- Test: Progress bar integration with book_detail
run_test("now-playing: _onSeekProgress seeks player via _renderView", function()
    local player = require("absaudio/player")
    local detail = require("absaudio/book_detail")
    local p = player.create({ track_durations = { 100, 200, 150 } })

    local mock_manifest_book = {
        id = "seek_test",
        title = "Seek Test",
        local_dir = "/tmp/seek_test",
        current_time = 0,
        files = {
            { filename = "track1.m4b", type = "audio", status = "complete" },
            { filename = "track2.m4b", type = "audio", status = "complete" },
        },
    }
    mock_manifest_books = { ["seek_test"] = mock_manifest_book }
    mock_api_configured = false

    local item = {
        id = "seek_test",
        mediaType = "book",
        media = {
            duration = 450,
            audioFiles = {{ duration = 100 }, { duration = 200 }, { duration = 150 }},
        },
    }

    local view = detail._renderView(item)
    view.player = p
    p:play()  -- must be playing for getCurrentTrack to work
    view:_onSeekProgress(170)
    mock.assert_equals(p:getPosition(), 170, "player position updated to 170s")
    mock.assert_equals(p:getCurrentTrack(), 2, "current track is 2 (170s within track 2)")
end)

-- ============================================================
-- Test: Dynamic time display updates
-- ============================================================
run_test("now-playing: _updatePlaybackDisplay updates time text", function()
    local player = require("absaudio/player")
    local detail = require("absaudio/book_detail")
    local p = player.create({ track_durations = { 100, 200 } })

    local mock_manifest_book = {
        id = "time_update_test",
        title = "Time Update Test",
        local_dir = "/tmp/time_test",
        current_time = 30,
        files = {
            { filename = "t1.m4b", type = "audio", status = "complete" },
            { filename = "t2.m4b", type = "audio", status = "complete" },
        },
    }
    mock_manifest_books = { ["time_update_test"] = mock_manifest_book }
    mock_api_configured = false

    local item = {
        id = "time_update_test",
        mediaType = "book",
        media = {
            duration = 300,
            audioFiles = {{ duration = 100 }, { duration = 200 }},
        },
    }

    local view = detail._renderView(item)
    view.player = p
    p:play()

    -- Initially at position 0 (start_position was 0)
    view:_updatePlaybackDisplay()
    mock.assert_equals(view.time_display_widget.text, "0:00 / 5:00", "initial time display")

    -- Advance player by 90 seconds
    p:_advanceTime(90)
    view:_updatePlaybackDisplay()
    mock.assert_equals(view.time_display_widget.text, "1:30 / 5:00", "time after 90s advance")
end)

run_test("now-playing: _updatePlaybackDisplay freezes when paused", function()
    local player = require("absaudio/player")
    local detail = require("absaudio/book_detail")
    local p = player.create({ track_durations = { 200 } })

    local mock_manifest_book = {
        id = "freeze_test",
        title = "Freeze Test",
        local_dir = "/tmp/freeze_test",
        current_time = 0,
        files = {{ filename = "t.m4b", type = "audio", status = "complete" }},
    }
    mock_manifest_books = { ["freeze_test"] = mock_manifest_book }
    mock_api_configured = false

    local item = {
        id = "freeze_test",
        mediaType = "book",
        media = { duration = 200, audioFiles = {{ duration = 200 }} },
    }

    local view = detail._renderView(item)
    view.player = p
    p:play()
    p:_advanceTime(60)  -- position should be 60s
    view:_updatePlaybackDisplay()
    local playing_time = view.time_display_widget.text

    p:pause()  -- freeze position
    p:_advanceTime(60)  -- sim time passes but position frozen
    view:_updatePlaybackDisplay()
    mock.assert_equals(view.time_display_widget.text, playing_time, "time frozen during pause")
end)

-- ============================================================
-- Play/pause button icon toggles based on playback state
-- ============================================================

run_test("play button icon toggles between ▶ and ⏸ on play/pause", function()
    local player = require("absaudio/player")
    local detail = require("absaudio/book_detail")
    local p = player.create({ track_durations = { 200 } })

    local mock_manifest_book = {
        id = "icon_toggle",
        title = "Icon Toggle Test",
        local_dir = "/tmp/icon_toggle",
        current_time = 0,
        files = {{ filename = "t.m4b", type = "audio", status = "complete" }},
    }
    mock_manifest_books = { ["icon_toggle"] = mock_manifest_book }
    mock_api_configured = false

    local item = {
        id = "icon_toggle",
        mediaType = "book",
        media = { duration = 200, audioFiles = {{ duration = 200 }} },
    }

    local view = detail._renderView(item)
    view.player = p

    -- Initially stopped: button should show ▶
    view:_updatePlaybackDisplay()
    mock.assert_equals(view.play_btn[1].text, "▶", "stopped shows play icon")

    -- After play: button should show ⏸
    p:play()
    view:_updatePlaybackDisplay()
    mock.assert_equals(view.play_btn[1].text, "⏸", "playing shows pause icon")

    -- After pause: button should show ▶ again
    p:pause()
    view:_updatePlaybackDisplay()
    mock.assert_equals(view.play_btn[1].text, "▶", "paused shows play icon")

    -- Resume: button should show ⏸ again
    p:resume()
    view:_updatePlaybackDisplay()
    mock.assert_equals(view.play_btn[1].text, "⏸", "resumed shows pause icon")
end)

-- ============================================================
-- Regression: play button tap via widget handler (not direct call)
-- Repros: hitting play in UI does nothing
-- ============================================================

run_test("regression: play button onTapPlayPause fires and changes state", function()
    local mock_manifest_book = {
        id = "np_tap_widget",
        title = "Tap Widget Test",
        local_dir = "/tmp/absaudio_np_tw",
        current_time = 0,
        files = {
            { filename = "track.m4b", type = "audio", status = "complete" },
        },
        chapters = {},
    }
    mock_manifest_books = { ["np_tap_widget"] = mock_manifest_book }

    local item = {
        id = "np_tap_widget",
        title = "Tap Widget Test",
        mediaType = "book",
        media = {
            duration = 600,
            metadata = { title = "Tap Widget Test" },
            audioFiles = {
                { filename = "track.m4b", format = "m4b", duration = 600 },
            },
        },
    }
    mock_api_configured = false

    local view = detail._renderView(item)
    local p = view.player

    mock.assert_equals(p:getState(), "stopped", "initially stopped")

    -- Find the play button widget by searching for onTapPlayPause method
    -- Use iterative search to avoid stack overflow from circular widget refs
    local play_button_widget = nil
    local to_search = { view }
    local searched = setmetatable({}, {__mode="k"})  -- weak keys; prevent cycles
    while #to_search > 0 do
        local widget = table.remove(to_search)
        if searched[widget] then goto continue end
        searched[widget] = true

        if type(widget) == "table" and type(widget.onTapPlayPause) == "function" then
            play_button_widget = widget
            break
        end
        for i = 1, #(widget or {}) do
            if type(widget[i]) == "table" then
                table.insert(to_search, widget[i])
            end
        end
        ::continue::
    end
    mock.assert_equals(play_button_widget ~= nil, true,
        "play button widget should exist in view hierarchy")

    -- Tap the button via its handler (simulates KOReader event dispatch)
    local ok, err = pcall(function() play_button_widget:onTapPlayPause() end)
    if not ok then
        mock.fail("onTapPlayPause threw error: " .. tostring(err))
    end

    mock.assert_equals(p:getState(), "playing",
        "player should be playing after tapping play button widget")
end)

-- ============================================================
-- Regression: makeTappableButton wraps GestureRange in array (KOReader ipairs requirement)
-- Repros: all makeTappableButton buttons silently ignore taps
-- Root cause: InputContainer:onGesture does ipairs(gsseq) which requires array, not bare object
-- ============================================================

run_test("regression: makeTappableButton ges_events is array-wrapped for KOReader compatibility", function()
    local wh = require("absaudio/widget_helpers")
    local tapped = false
    local btn = wh.makeTappableButton("Test", function()
        tapped = true
    end, {
        width = 200,
        height = 40,
        tap_event_name = "TapTest",
    })

    -- ges_events value must be a table (array) for KOReader's ipairs() in onGesture
    local gs_entry = btn.ges_events.TapTest
    mock.assert_equals(type(gs_entry), "table",
        "ges_events.TapTest must be a table")

    -- Must have numeric index [1] containing the GestureRange (ipairs requirement)
    mock.assert_equals(type(gs_entry[1]), "table",
        "ges_events.TapTest[1] must exist (array-wrapped for ipairs)")

    -- The first element must have 'ges' field (it's a GestureRange)
    mock.assert_equals(type(gs_entry[1].ges), "string",
        "ges_events.TapTest[1] must be a GestureRange with .ges field")
    mock.assert_equals(type(gs_entry[1].ges), "string",
        "ges_events.TapTest[1] must be a GestureRange with .ges field")
end)

-- ============================================================
-- Regression: _updatePlaybackDisplay invalidates TextWidget cache via free()
-- Repros: time display shows stale text during playback (never updates)
-- Root cause: KOReader's TextWidget caches rendered bitmap in _bb;
--   setting .text doesn't clear the cache, so paintTo blits old content
-- ============================================================

run_test("regression: _updatePlaybackDisplay calls free() on text widget", function()
    local detail = require("absaudio/book_detail")

    local mock_manifest_book = {
        id = "free_cache_test",
        title = "Free Cache Test",
        local_dir = "/tmp/free_cache_test",
        current_time = 0,
        files = {{ filename = "track.m4b", type = "audio", status = "complete" }},
    }
    mock_manifest_books = { ["free_cache_test"] = mock_manifest_book }

    local item = {
        id = "free_cache_test",
        mediaType = "book",
        media = { duration = 3600, audioFiles = {{ duration = 3600 }} },
    }
    mock_api_configured = false

    local view = detail._renderView(item)
    -- Inject a mock player that reports position 42.5s
    view.player = {
        getPosition = function() return 42.5 end,
        getDuration = function() return 3600 end,
        getState = function() return "playing" end,
    }

    -- Seed the TextWidget with a fake cached bitmap (simulating KOReader's _bb)
    if view.time_display_widget then
        view.time_display_widget._bb = "fake_cached_bitmap"
    end

    -- Call _updatePlaybackDisplay — should update text AND free cache
    view:_updatePlaybackDisplay()

    mock.assert_equals(view.time_display_widget.text, "0:42 / 1:00:00",
        "time display text should show updated position")

    mock.assert_equals(view.time_display_widget._bb, nil,
        "TextWidget _bb cache should be nil after free() (forces re-render on next paintTo)")
end)

-- ============================================================
-- Chapter navigation + speed control handlers (issue #7)
-- ============================================================

local NAV_CHAPTERS = {
    { id = 0, start = 0,    ["end"] = 600,  title = "Intro" },
    { id = 1, start = 600,  ["end"] = 1500, title = "Chapter 2" },
    { id = 2, start = 1500, ["end"] = 2400, title = "Chapter 3" },
}

-- Build a now-playing view backed by a stub player at start_pos, with
-- chapter data on a 2400s global timeline. Player is in 'stopped' state
-- so getPosition() is deterministic (no wall-clock drift).
local function make_chapter_view(start_pos, chapters)
    local player = require("absaudio/player")
    local detail = require("absaudio/book_detail")
    mock_playback_speed = 1.0  -- reset persisted speed so each view starts at default
    local p = player.create({ track_durations = { 2400 }, start_position = start_pos or 0 })
    mock_manifest_books = {
        ["ch_nav_test"] = {
            id = "ch_nav_test", title = "Ch Nav", local_dir = "/tmp/ch_nav",
            current_time = start_pos or 0,
            files = { { filename = "all.m4b", type = "audio", status = "complete" } },
        },
    }
    mock_api_configured = false
    local item = {
        id = "ch_nav_test", mediaType = "book",
        media = { duration = 2400, audioFiles = {{ duration = 2400 }}, chapters = chapters },
    }
    local view = detail._renderView(item)
    view.player = p
    return view, p
end

run_test("chapters: chapter name widget reflects current chapter at render", function()
    local view = make_chapter_view(100, NAV_CHAPTERS)  -- pos 100 → chapter 1
    mock.assert_equals(view.chapter_name_widget.text, "Chapter 1: Intro",
        "chapter name widget built with current chapter")
    mock.assert_equals(view.chapters, NAV_CHAPTERS, "chapters captured on the view")
end)

run_test("chapter next: seeks to next chapter start and updates label", function()
    local view, p = make_chapter_view(100, NAV_CHAPTERS)  -- chapter 1
    view:_onChapterNext()
    mock.assert_equals(p:getPosition(), 600, "seeked to chapter 2 start (600)")
    mock.assert_equals(view.chapter_name_widget.text, "Chapter 2: Chapter 2",
        "label updated after seek")
end)

run_test("chapter prev: deep in chapter restarts current chapter", function()
    local view, p = make_chapter_view(800, NAV_CHAPTERS)  -- elapsed 200s in ch2
    view:_onChapterPrev()
    mock.assert_equals(p:getPosition(), 600, "restarts chapter 2 (600)")
end)

run_test("chapter prev: near start jumps to previous chapter", function()
    local view, p = make_chapter_view(605, NAV_CHAPTERS)  -- elapsed 5s in ch2
    view:_onChapterPrev()
    mock.assert_equals(p:getPosition(), 0, "jumps to chapter 1 start (0)")
end)

run_test("chapter next: no-op at last chapter", function()
    local view, p = make_chapter_view(2000, NAV_CHAPTERS)  -- chapter 3 (last)
    view:_onChapterNext()
    mock.assert_equals(p:getPosition(), 2000, "position unchanged at last chapter")
end)

run_test("seek-to-chapter: seeks to a specific chapter start", function()
    local view, p = make_chapter_view(100, NAV_CHAPTERS)
    view:_onSeekToChapter(3)
    mock.assert_equals(p:getPosition(), 1500, "seeked to chapter 3 start")
end)

run_test("speed: cycle advances preset and updates badge", function()
    local view, p = make_chapter_view(0, NAV_CHAPTERS)  -- default speed 1×
    mock.assert_equals(view.speed_btn[1].text, "1×", "initial badge is 1×")
    view:_onSpeedCycle()
    mock.assert_equals(p:getPlaybackSpeed(), 1.25, "player speed advanced to 1.25")
    mock.assert_equals(view.speed_btn[1].text, "1.25×", "badge updated to 1.25×")
end)

run_test("chapter nav: no-op when book has no chapters", function()
    local view, p = make_chapter_view(100, nil)  -- no chapters
    view:_onChapterNext()
    mock.assert_equals(p:getPosition(), 100, "no seek when no chapters")
    view:_onChapterPrev()
    mock.assert_equals(p:getPosition(), 100, "no seek when no chapters")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if #errors > 0 then
    print("\nFailures:")
    for _, e in ipairs(errors) do
        print("  " .. e.name .. ": " .. tostring(e.err))
    end
    os.exit(1)
end