-- Library browser widget for absaudio.koplugin  [v2-synchronous]
-- Fullscreen scrollable list of audiobooks from an ABS library.
-- Uses library_store for data and cover_cache for cover art.
print("[ABS-BROWSER] module loaded (v2-synchronous)")
--
-- Public API:
--   browser.show(callbacks)
--     callbacks: { on_back, on_book_tap }

local Blitbuffer = require("ffi/blitbuffer")
local BD = require("ui/bidi")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local Screen = Device.screen

local abs_logger = require("abs_logger")
local library_store = require("absaudio/library_store")

-- Try to load optional dependencies
local has_api, api = pcall(require, "api")
local has_cover_cache, cover_cache = pcall(require, "absaudio/cover_cache")

local browser = {}

-- Callbacks passed from caller
local _on_back = nil
local _on_book_tap = nil

-- Current browser state
local _current_page = 1
local _search_query = ""
local _view = nil  -- reference to current LibraryBrowserView instance

------------------------------------------------------------------------
-- Helper: format seconds as "Xh Ym" or "Ym" or "0m"
------------------------------------------------------------------------
local function format_duration(seconds)
    if not seconds or seconds <= 0 then return "0m" end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    if h > 0 then
        return string.format("%dh %dm", h, m)
    end
    return string.format("%dm", m)
end

------------------------------------------------------------------------
-- Library Browser View
------------------------------------------------------------------------
local LibraryBrowserView = FocusManager:extend{
    name = "absaudio_library_browser",
    is_editable = false,
    covers_fullscreen = true,
}

function LibraryBrowserView:init()
    -- Store reference for tap callbacks
    self.browser_ref = self

    -- Back key closes the browser
    if Device:hasKeys() then
        self.key_events = self.key_events or {}
        self.key_events.Close = { { Device.input.group.Back } }
    end

    -- Swipe down closes the browser
    if Device:isTouchDevice() then
        self.ges_events = self.ges_events or {}
        self.ges_events.Swipe = {
            GestureRange:new{
                ges = "swipe",
                range = function() return self.dimen end,
            },
        }
    end

    local screen_size = Screen:getSize()
    self.dimen = screen_size
    self.screen_width = screen_size.w
    self.screen_height = screen_size.h
    self.content_width = self.screen_width - 2 * Size.padding.large

    -- Build content
    self.content_group = VerticalGroup:new{ align = "left" }

    -- Top padding
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.large })

    -- Header bar: back button, title, sort button, search button
    self:_addHeader()

    -- Separator
    self:_addSeparator()

    -- Book list (populated from library_store)
    self:_addBookList()

    -- Load more button (if more pages)
    self:_addLoadMore()

    -- Bottom padding
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.large })

    -- Wrap in scrollable container
    self.scrollable = ScrollableContainer:new{
        dimen = Geom:new{
            w = self.screen_width,
            h = self.screen_height,
        },
        self.content_group,
    }

    -- Main frame — fullscreen, no borders
    self[1] = FrameContainer:new{
        width = self.screen_width,
        height = self.screen_height,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        self.scrollable,
    }
end

------------------------------------------------------------------------
-- Header bar with back, title, sort, and search
------------------------------------------------------------------------
function LibraryBrowserView:_addHeader()
    -- Back button (left)
    local back_text = TextWidget:new{
        text = "← " .. _("Back"),
        face = Font:getFace("cfont", 14),
        fgcolor = Blitbuffer.COLOR_BLUE,
    }
    local back_container = InputContainer:new{
        dimen = Geom:new{
            w = back_text:getSize().w + Size.padding.default,
            h = back_text:getSize().h + Size.padding.default,
        },
    }
    back_container.ges_events.TapBack = {
        GestureRange:new{
            ges = "tap",
            range = back_container.dimen,
        },
    }
    back_container.browser_ref = self.browser_ref
    function back_container:onTapBack()
        self.browser_ref:onClose()
        return true
    end
    back_container[1] = back_text

    -- Title "Library"
    local title_text = TextWidget:new{
        text = _("Library"),
        face = Font:getFace("tfont", 22),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    -- Sort button (right side)
    local sort_label = library_store.getCurrentSort():gsub("_", " ")
    local sort_text = TextWidget:new{
        text = "Sort: " .. sort_label,
        face = Font:getFace("cfont", 12),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }
    local sort_container = InputContainer:new{
        dimen = Geom:new{
            w = sort_text:getSize().w + Size.padding.default,
            h = sort_text:getSize().h + Size.padding.default,
        },
    }
    sort_container.ges_events.TapSort = {
        GestureRange:new{
            ges = "tap",
            range = sort_container.dimen,
        },
    }
    sort_container.browser_ref = self.browser_ref
    function sort_container:onTapSort()
        self.browser_ref:onCycleSort()
        return true
    end
    sort_container[1] = sort_text

    -- Search button
    local search_text = TextWidget:new{
        text = "🔍",
        face = Font:getFace("cfont", 16),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }
    local search_container = InputContainer:new{
        dimen = Geom:new{
            w = search_text:getSize().w + Size.padding.default,
            h = search_text:getSize().h + Size.padding.default,
        },
    }
    search_container.ges_events.TapSearch = {
        GestureRange:new{
            ges = "tap",
            range = search_container.dimen,
        },
    }
    search_container.browser_ref = self.browser_ref
    function search_container:onTapSearch()
        self.browser_ref:onSearch()
        return true
    end
    search_container[1] = search_text

    -- Arrange in horizontal group
    local header = HorizontalGroup:new{
        align = "center",
        back_container,
        HorizontalSpan:new{ width = Size.padding.default },
        CenterContainer:new{
            dimen = Geom:new{
                w = self.content_width - back_container.dimen.w
                    - sort_container.dimen.w - search_container.dimen.w
                    - 3 * Size.padding.default,
                h = title_text:getSize().h,
            },
            title_text,
        },
        HorizontalSpan:new{ width = Size.padding.small },
        sort_container,
        search_container,
    }
    table.insert(self.content_group, header)

    -- Search query indicator (if searching)
    if _search_query and _search_query ~= "" then
        local query_label = TextWidget:new{
            text = _("Searching: ") .. _search_query,
            face = Font:getFace("cfont", 12),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
        table.insert(self.content_group, query_label)
    end

    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })
end

------------------------------------------------------------------------
-- Separator line
------------------------------------------------------------------------
function LibraryBrowserView:_addSeparator()
    table.insert(self.content_group, LineWidget:new{
        background = Blitbuffer.COLOR_DARK_GRAY,
        dimen = Geom:new{
            w = self.content_width,
            h = Size.line.thin,
        },
    })
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })
end

------------------------------------------------------------------------
-- Book list — renders current page of items
------------------------------------------------------------------------
function LibraryBrowserView:_addBookList()
    local result = library_store.getItems({
        page = _current_page,
        per_page = 25,
        search = _search_query,
    })

    self._total_pages = result.total_pages
    self._total_items = result.total_items

    if #result.items == 0 then
        local empty_msg
        if _search_query and _search_query ~= "" then
            empty_msg = _("No books match \"") .. _search_query .. "\""
        else
            empty_msg = _("No books in this library.")
        end
        local empty_text = TextWidget:new{
            text = empty_msg,
            face = Font:getFace("cfont", 16),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
        table.insert(self.content_group, CenterContainer:new{
            dimen = Geom:new{ w = self.content_width, h = empty_text:getSize().h + Size.padding.large },
            empty_text,
        })
        return
    end

    -- Page indicator
    local page_info = string.format(_("Page %d of %d  (%d books)"),
        result.page, result.total_pages, result.total_items)
    local page_text = TextWidget:new{
        text = page_info,
        face = Font:getFace("cfont", 12),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }
    table.insert(self.content_group, CenterContainer:new{
        dimen = Geom:new{ w = self.content_width, h = page_text:getSize().h },
        page_text,
    })
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })

    -- Render each book row
    for _, item in ipairs(result.items) do
        self:_addBookRow(item)
    end
end

------------------------------------------------------------------------
-- Single book row: cover thumbnail + title/author/duration
------------------------------------------------------------------------
function LibraryBrowserView:_addBookRow(item)
    local row_height = 80
    local thumb_width = 60
    local thumb_height = 80
    local text_area_width = self.content_width - thumb_width - Size.padding.default

    -- Cover thumbnail
    local cover_widget
    local cover_path = nil
    if has_cover_cache and cover_cache.hasCachedCover(item.id) then
        cover_path = cover_cache.getCoverPath(item.id)
    end

    if cover_path then
        cover_widget = ImageWidget:new{
            file = cover_path,
            width = thumb_width,
            height = thumb_height,
            scale_factor = 0,
        }
    else
        -- Placeholder rectangle
        cover_widget = FrameContainer:new{
            width = thumb_width,
            height = thumb_height,
            background = Blitbuffer.COLOR_LIGHT_GRAY,
            bordersize = 0,
            padding = 0,
            CenterContainer:new{
                dimen = Geom:new{ w = thumb_width, h = thumb_height },
                TextWidget:new{
                    text = "🎵",
                    face = Font:getFace("cfont", 20),
                    fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                },
            },
        }
    end

    -- Text info: title, author, duration
    local title_str = library_store.getItemTitle(item)
    if title_str == "" then title_str = _("Unknown Title") end
    local author_str = library_store.getItemAuthor(item)
    local duration_str = ""
    if item.media and item.media.duration and item.media.duration > 0 then
        duration_str = format_duration(item.media.duration)
    end

    -- Progress indicator
    local progress_str = ""
    if item.userMediaProgress then
        if item.userMediaProgress.isFinished then
            progress_str = " ✓"
        elseif item.userMediaProgress.currentTime and item.media and item.media.duration then
            local pct = math.floor(item.userMediaProgress.currentTime / item.media.duration * 100)
            progress_str = string.format(" (%d%%)", pct)
        end
    end

    local info_lines = title_str
    if author_str ~= "" then
        info_lines = info_lines .. "\n" .. author_str
    end
    if duration_str ~= "" then
        info_lines = info_lines .. "\n" .. duration_str .. progress_str
    elseif progress_str ~= "" then
        info_lines = info_lines .. "\n" .. progress_str
    end

    local info_widget = TextBoxWidget:new{
        text = info_lines,
        face = Font:getFace("cfont", 14),
        width = text_area_width,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    -- Assemble row: [cover] [text]
    local row_content = HorizontalGroup:new{
        align = "center",
        cover_widget,
        HorizontalSpan:new{ width = Size.padding.default },
        LeftContainer:new{
            dimen = Geom:new{ w = text_area_width, h = row_height },
            info_widget,
        },
    }

    -- Wrap in tappable container
    local row_container = InputContainer:new{
        dimen = Geom:new{
            w = self.content_width,
            h = row_height,
        },
    }
    row_container.ges_events.TapBook = {
        GestureRange:new{
            ges = "tap",
            range = row_container.dimen,
        },
    }
    row_container.browser_ref = self.browser_ref
    row_container.item = item
    function row_container:onTapBook()
        self.browser_ref:onBookTap(self.item)
        return true
    end
    row_container[1] = row_content

    table.insert(self.content_group, row_container)
end

------------------------------------------------------------------------
-- Load more button
------------------------------------------------------------------------
function LibraryBrowserView:_addLoadMore()
    local result = library_store.getItems({
        page = _current_page,
        per_page = 25,
        search = _search_query,
    })

    if result.total_pages > _current_page then
        local more_text = TextWidget:new{
            text = _("Load more…"),
            face = Font:getFace("cfont", 16),
            fgcolor = Blitbuffer.COLOR_BLUE,
        }
        local more_container = InputContainer:new{
            dimen = Geom:new{
                w = self.content_width,
                h = more_text:getSize().h + Size.padding.large,
            },
        }
        more_container.ges_events.TapMore = {
            GestureRange:new{
                ges = "tap",
                range = more_container.dimen,
            },
        }
        more_container.browser_ref = self.browser_ref
        function more_container:onTapMore()
            self.browser_ref:onLoadMore()
            return true
        end
        more_container[1] = CenterContainer:new{
            dimen = Geom:new{
                w = self.content_width,
                h = more_text:getSize().h + Size.padding.large,
            },
            more_text,
        }
        table.insert(self.content_group, more_container)
    end
end

------------------------------------------------------------------------
-- Navigation handlers
------------------------------------------------------------------------
function LibraryBrowserView:onClose()
    UIManager:close(self)
    if _on_back then
        _on_back()
    end
    return true
end

function LibraryBrowserView:onSwipe(arg, ges_ev)
    if ges_ev.direction == "south" then
        self:onClose()
    end
    return true
end

function LibraryBrowserView:onBookTap(item)
    abs_logger.info("Book tapped: " .. (item.title or item.id))
    if _on_book_tap then
        _on_book_tap(item)
    end
    return true
end

function LibraryBrowserView:onCycleSort()
    local modes = library_store.getSortModes()
    local current = library_store.getCurrentSort()

    -- Find current index and advance to next
    local next_sort = modes[1]
    for i, mode in ipairs(modes) do
        if mode == current and i < #modes then
            next_sort = modes[i + 1]
            break
        end
    end

    library_store.setSort(next_sort)
    _current_page = 1  -- reset to first page
    abs_logger.verbose("Sort cycled to: " .. next_sort)

    -- Re-render
    self:_refresh()
end

function LibraryBrowserView:onSearch()
    local input_dialog = InputDialog:new{
        title = _("Search library"),
        input = _search_query or "",
        input_type = "text",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        _search_query = input_dialog:getInputText()
                        _current_page = 1
                        UIManager:close(input_dialog)
                        self:_refresh()
                    end,
                },
            },
            {
                {
                    text = _("Clear search"),
                    callback = function()
                        _search_query = ""
                        _current_page = 1
                        UIManager:close(input_dialog)
                        self:_refresh()
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
    return true
end

function LibraryBrowserView:onLoadMore()
    _current_page = _current_page + 1
    abs_logger.verbose("Loading page " .. _current_page)
    self:_refresh()
end

function LibraryBrowserView:_refresh()
    UIManager:close(self)
    _view = LibraryBrowserView:new{}
    UIManager:show(_view)
end

------------------------------------------------------------------------
-- Public: show library browser
-- Fetches the first ABS library, loads items, and displays the browser.
------------------------------------------------------------------------
--- Public: show library browser
--- Fetches the first ABS library, loads items, and displays the browser.
------------------------------------------------------------------------
function browser.show(callbacks)
    callbacks = callbacks or {}
    _on_back = callbacks.on_back
    _on_book_tap = callbacks.on_book_tap
    _current_page = 1
    _search_query = ""
    _view = nil

    print("[ABS-BROWSER] show() called")
    abs_logger.info("Opening library browser")

    -- First, we need to get the library ID
    if not has_api or not api.is_configured() then
        print("[ABS-BROWSER] api not configured, calling on_back")
        if _on_back then _on_back() end
        return
    end

    -- Do everything synchronously
    local ok, err = pcall(function()
        print("[ABS-BROWSER] inside pcall, fetching libraries...")
        local api_ok, data = api.getLibraries()
        local libraries = (data and data.libraries) or {}
        print("[ABS-BROWSER] libraries response: ok=" .. tostring(api_ok) .. " count=" .. #libraries)

        if not api_ok or #libraries == 0 then
            print("[ABS-BROWSER] no libraries found")
            UIManager:show(InfoMessage:new{
                text = _("No libraries found. Check your server configuration."),
                timeout = 3,
            })
            if _on_back then _on_back() end
            return
        end

        local library_id = libraries[1].id
        print("[ABS-BROWSER] using library: " .. tostring(library_id))

        -- Fetch all items from this library
        local fetch_ok, fetch_err = library_store.fetchAll(library_id)
        print("[ABS-BROWSER] fetchAll result: ok=" .. tostring(fetch_ok))

        if not fetch_ok then
            print("[ABS-BROWSER] fetchAll failed: " .. tostring(fetch_err))
            UIManager:show(InfoMessage:new{
                text = _("Failed to load library. Check your connection."),
                timeout = 3,
            })
            if _on_back then _on_back() end
            return
        end

        print("[ABS-BROWSER] initializing cover cache...")
        if has_cover_cache then
            local config = require("config")
            local cache_dir = (config.get("download_dir") or "/tmp") .. "/abs_covers"
            cover_cache.init(cache_dir)
        end

        print("[ABS-BROWSER] creating LibraryBrowserView...")
        _view = LibraryBrowserView:new{}
        print("[ABS-BROWSER] showing view...")
        UIManager:show(_view)
        print("[ABS-BROWSER] view shown!")

        -- Schedule batch cover fetch + refresh for current page
        if has_cover_cache then
            browser._scheduleCoverFetch()
        end
    end)

    if not ok then
        print("[ABS-BROWSER] pcall FAILED: " .. tostring(err))
        UIManager:show(InfoMessage:new{
            text = _("Error loading library: ") .. tostring(err),
            timeout = 5,
        })
    end
end

------------------------------------------------------------------------
-- Batch cover fetch for current page items
------------------------------------------------------------------------
function browser._scheduleCoverFetch()
    UIManager:scheduleIn(1, function()
        if not _view then return end
        local result = library_store.getItems({
            page = _current_page,
            per_page = _per_page,
            search = _search_query ~= "" and _search_query or nil,
        })
        local fetched_any = false
        for _, item in ipairs(result.items) do
            if not cover_cache.hasCachedCover(item.id) then
                local ok = cover_cache.fetchAndCache(item.id)
                if ok then fetched_any = true end
            end
        end
        -- Refresh view to show newly cached covers
        if fetched_any and _view then
            _view:_refresh()
        end
    end)
end

return browser
