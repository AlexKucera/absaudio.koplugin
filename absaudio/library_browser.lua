-- Library browser widget for absaudio.koplugin  [v2-synchronous]
-- Fullscreen scrollable list of audiobooks from an ABS library.
-- Uses library_store for data and cover_cache for cover art.
--
-- Public API:
--   browser.show(data)
--     data: {} (navigation via navigator module)

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
local IconWidget = require("ui/widget/iconwidget")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
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
local widget_helpers = require("absaudio/widget_helpers")

-- Try to load optional dependencies
local has_api, api = pcall(require, "api")
local has_cover_cache, cover_cache = pcall(require, "absaudio/cover_cache")
local has_navigator, nav = pcall(require, "absaudio/navigator")
local has_manifest, manifest = pcall(require, "manifest")
local has_config, config = pcall(require, "config")
local downloader = require("absaudio/downloader")
local has_progress, progress = pcall(require, "absaudio/download_progress")

local browser = {}

-- Instance state is stored on the LibraryBrowserView (self.current_page,
-- self.search_query). Only _view remains module-level as a reference to
-- the active instance.
local _view = nil  -- reference to current LibraryBrowserView instance


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

    -- We do NOT register ges_events.Swipe here so that swipe events
    -- propagate to the ScrollableContainer child for scrolling.
    -- Close via Back key (key_events.Close) or the ← Back button.

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
    widget_helpers.addSeparator(self.content_group, self.content_width)

    -- Book list (populated from library_store)
    self:_addBookList()

    -- Page navigation (Prev / Page X/Y / Next)
    self:_addPageNav()

    -- Bottom padding
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.large })

    -- Wrap in scrollable container
    self.cropping_widget = ScrollableContainer:new{
        dimen = Geom:new{
            w = self.screen_width,
            h = self.screen_height,
        },
        show_parent = self,
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
        self.cropping_widget,
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

    -- Search button (icon + optional query text)
    local search_icon = IconWidget:new{
        icon = "appbar.search",
        width = Size.padding.default * 3,
        height = Size.padding.default * 3,
        alpha = true,
    }
    local search_elements = { search_icon }
    if self.search_query and self.search_query ~= "" then
        local search_label = TextWidget:new{
            text = self.search_query,
            face = Font:getFace("cfont", 12),
            fgcolor = Blitbuffer.COLOR_BLUE,
        }
        table.insert(search_elements, HorizontalSpan:new{ width = Size.padding.small })
        table.insert(search_elements, search_label)
    end
    local search_inner = HorizontalGroup:new(search_elements)
    local search_container = InputContainer:new{
        dimen = Geom:new{
            w = search_icon:getSize().w + Size.padding.default * 2 + (self.search_query and self.search_query ~= "" and 60 or 0),
            h = search_icon:getSize().h + Size.padding.default * 2,
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
    search_container[1] = search_inner

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
    if self.search_query and self.search_query ~= "" then
        local query_label = TextWidget:new{
            text = _("Searching: ") .. self.search_query,
            face = Font:getFace("cfont", 12),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
        table.insert(self.content_group, query_label)
    end

    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })
end

------------------------------------------------------------------------
-- Calculate items per page based on screen height and row height
function LibraryBrowserView:_getPerPage()
    local row_height = Screen:scaleBySize(100)
    -- Measure actual heights of widgets already added to content_group
    -- (header, separator, search indicator). Page nav hasn't been added yet
    -- so we estimate it.
    local used_h = 0
    for _, w in ipairs(self.content_group) do
        used_h = used_h + w:getSize().h
    end
    -- Estimate nav bar height (not yet added)
    local nav_h = Size.padding.large * 2 + 30
    local available = self.screen_height - used_h - nav_h
    return math.max(1, math.floor(available / row_height))
end
-- Book list — renders current page of items
------------------------------------------------------------------------
function LibraryBrowserView:_addBookList()
    abs_logger.verbose("_addBookList: search='" .. tostring(self.search_query) .. "' page=" .. tostring(self.current_page))
    local result = library_store.getItems({
        page = self.current_page,
        per_page = self:_getPerPage(),
        search = self.search_query,
    })
    abs_logger.verbose("_addBookList: getItems returned " .. #result.items .. " items (total " .. result.total_items .. ")")

    self._total_pages = result.total_pages
    self._total_items = result.total_items

    if #result.items == 0 then
        local empty_msg
        if self.search_query and self.search_query ~= "" then
            empty_msg = _("No books match \"") .. self.search_query .. "\""
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
    local row_height = Screen:scaleBySize(100)
    local thumb_width = Screen:scaleBySize(80)
    local thumb_height = Screen:scaleBySize(100)
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
                    face = Font:getFace("cfont", Screen:scaleBySize(22)),
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
        duration_str = widget_helpers.format_duration(item.media.duration)
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
        face = Font:getFace("cfont", 16),
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

-----------------------------------------------------------------------
-- Page navigation bar (Prev / Page X of Y / Next)
-----------------------------------------------------------------------
function LibraryBrowserView:_addPageNav()
    local total_pages = self._total_pages or 1

    -- Only show page nav when there's more than one page
    if total_pages <= 1 then return end

    local nav_height = Size.padding.large * 2 + 30

    -- Page info text
    local page_text = TextWidget:new{
        text = _(string.format("Page %d / %d", self.current_page, total_pages)),
        face = Font:getFace("cfont", 14),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }

    -- Prev button
    local prev_enabled = self.current_page > 1
    local prev_text = TextWidget:new{
        text = _("← Prev"),
        face = Font:getFace("cfont", 16),
        fgcolor = prev_enabled and Blitbuffer.COLOR_BLUE or Blitbuffer.COLOR_GRAY,
    }
    local prev_btn = InputContainer:new{
        dimen = Geom:new{
            w = self.content_width * 0.3,
            h = nav_height,
        },
    }
    if prev_enabled then
        prev_btn.ges_events.TapPrev = {
            GestureRange:new{ ges = "tap", range = prev_btn.dimen },
        }
        prev_btn.browser_ref = self.browser_ref
        function prev_btn:onTapPrev()
            self.browser_ref:onPrevPage()
            return true
        end
    end
    prev_btn[1] = CenterContainer:new{
        dimen = Geom:new{ w = self.content_width * 0.3, h = nav_height },
        prev_text,
    }

    -- Next button
    local next_enabled = self.current_page < total_pages
    local next_text = TextWidget:new{
        text = _("Next →"),
        face = Font:getFace("cfont", 16),
        fgcolor = next_enabled and Blitbuffer.COLOR_BLUE or Blitbuffer.COLOR_GRAY,
    }
    local next_btn = InputContainer:new{
        dimen = Geom:new{
            w = self.content_width * 0.3,
            h = nav_height,
        },
    }
    if next_enabled then
        next_btn.ges_events.TapNext = {
            GestureRange:new{ ges = "tap", range = next_btn.dimen },
        }
        next_btn.browser_ref = self.browser_ref
        function next_btn:onTapNext()
            self.browser_ref:onNextPage()
            return true
        end
    end
    next_btn[1] = CenterContainer:new{
        dimen = Geom:new{ w = self.content_width * 0.3, h = nav_height },
        next_text,
    }

    -- Spacer for center text
    local spacer = HorizontalSpan:new{ width = self.content_width * 0.4 }

    local nav_bar = HorizontalGroup:new{
        dimen = Geom:new{
            w = self.content_width,
            h = nav_height,
        },
        prev_btn,
        CenterContainer:new{
            dimen = Geom:new{ w = self.content_width * 0.4, h = nav_height },
            page_text,
        },
        next_btn,
    }

    -- Top separator line
    local sep = LineWidget:new{
        dimen = Geom:new{ w = self.content_width, h = Size.line.thin },
    }

    table.insert(self.content_group, sep)
    table.insert(self.content_group, nav_bar)
end

function LibraryBrowserView:onPrevPage()
    if self.current_page > 1 then
        self.current_page = self.current_page - 1
        abs_logger.verbose("Previous page: " .. self.current_page)
        self:_refresh()
    end
end

function LibraryBrowserView:onNextPage()
    self.current_page = self.current_page + 1
    abs_logger.verbose("Loading page " .. self.current_page)
    self:_refresh()
end

function LibraryBrowserView:_refresh()
    -- Propagate instance state to the new view
    local saved_current_page = self.current_page
    local saved_search_query = self.search_query

    UIManager:close(self)
    _view = LibraryBrowserView:new{
        current_page = saved_current_page,
        search_query = saved_search_query,
    }

    -- Keep navigator state in sync so subsequent pop() targets the live widget
    if has_navigator then
        nav._setCurrent(_view)
    end

    UIManager:show(_view)
    UIManager:setDirty(_view, "full")
end

function LibraryBrowserView:onClose()
    if has_navigator then
        nav.pop()              -- nav.pop() owns UIManager:close(self)
    else
        UIManager:close(self)   -- standalone fallback
    end
end

function LibraryBrowserView:onBookTap(item)
    abs_logger.info("Book tapped: " .. (item.title or item.id))
    if has_navigator then
        nav.push("detail", {
            item = item,
            on_download = function(data)
                -- data may be a plain item or { item=..., ebook_only=true }
                local book_item = data.item or data
                local ebook_only = data.ebook_only or false
                self:_onDownloadBook(book_item, ebook_only)
            end,
            on_delete = function(book_item)
                self:_onDeleteBook(book_item)
            end,
        })
    end
    return true
end

------------------------------------------------------------------------
-- Download handler — triggers download pipeline
-- @param item table  ABS item to download
------------------------------------------------------------------------
function LibraryBrowserView:_onDownloadBook(item, ebook_only)
    abs_logger.info("Download requested: " .. (item.title or item.id)
        .. (ebook_only and " (ebook)" or ""))
    if not has_manifest or not has_config then
        UIManager:show(InfoMessage:new{ text = _("Download not available") })
        return
    end
    manifest.init()

    -- Ebook download path
    if ebook_only then
        local ok, result = downloader.prepare_ebook_download(item, manifest, config)
        if not ok then
            UIManager:show(InfoMessage:new{
                text = _("No ebook files found for this book."),
                timeout = 3,
            })
            return
        end
        -- TODO: schedule actual ebook file download (same pipeline as audio)
        UIManager:show(InfoMessage:new{
            text = _("Ebook download prepared."),
            timeout = 3,
        })
        return
    end

    local ok, result = downloader.prepare_download(item, manifest, config)
    if not ok then
        if result == "already_downloaded" then
            -- Gap 3: Re-download prompt
            UIManager:show(ConfirmBox:new{
                text = _("Already downloaded. Re-download?"),
                ok_text = _("Re-download"),
                ok_callback = function()
                    local lfs = _G.lfs or require("lfs")
                    local fs = {
                        delete_file = function(path) os.remove(path) end,
                        delete_dir = function(path) lfs.rmdir(path) end,
                    }
                    downloader.delete_book(item.id, manifest, fs)
                    self:_onDownloadBook(item)
                end,
            })
        else
            UIManager:show(InfoMessage:new{ text = _("No audio files found for this book.") })
        end
        return
    end

    -- Gap 2: Free space check
    local needed = downloader.calculate_download_size(result.files)
    if needed > 0 then
        local download_dir = config.get("download_dir") or "/tmp"
        local free_bytes = downloader.get_free_space(download_dir)
        if free_bytes and not downloader.check_free_space(needed, free_bytes) then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Insufficient disk space. Need %s, have %s."),
                    downloader.format_bytes(needed), downloader.format_bytes(free_bytes)),
                timeout = 5,
            })
            return
        end
    end

    -- Gap 8: Full download pipeline with progress widget
    local state = downloader.create_download_state()
    state.start_time = os.time()
    state.total_files = #result.files
    state.total_bytes = downloader.calculate_download_size(result.files)

    -- Show progress widget
    if has_progress then
        progress.show({
            state = state,
            on_cancel = function()
                state:cancel()
            end,
        })
    end

    -- Build deps
    local lfs = _G.lfs or require("lfs")
    local deps = {
        manifest = manifest,
        api = require("api"),
        fs = {
            mkdir = function(path)
                -- Recursively create directory
                local parts = {}
                for part in path:gmatch("[^/]+") do
                    table.insert(parts, part)
                end
                local current = ""
                for _, part in ipairs(parts) do
                    current = current .. "/" .. part
                    if not lfs.attributes(current) then
                        lfs.mkdir(current)
                    end
                end
            end,
            open = function(path, mode)
                return io.open(path, mode)
            end,
            get_file_size = function(path)
                local attr = lfs.attributes(path)
                return attr and attr.size or nil
            end,
        },
        state = state,
    }

    -- Get files to download
    local files = downloader.select_files_to_download(result.files)
    local self_ref = self
    local entry = result

    -- Schedule file-by-file download (coroutine-based for UI responsiveness)
    local function schedule_next(idx)
        if idx > #files or state:is_cancelled() then
            -- Close progress widget
            if has_progress then progress.close() end

            local msg = state:is_cancelled()
                and _("Download cancelled.")
                or _("Download complete!")
            UIManager:show(InfoMessage:new{ text = msg, timeout = 3 })

            -- Refresh detail view by popping and re-pushing
            if has_navigator then
                nav.pop()
                UIManager:scheduleIn(0.1, function()
                    nav.push("detail", {
                        item = item,
                        on_download = function(b) self_ref:_onDownloadBook(b) end,
                        on_delete = function(b) self_ref:_onDeleteBook(b) end,
                    })
                end)
            end
            return
        end

        state.current_file = idx

        -- Use chunked (coroutine-based) download for UI responsiveness
        local handle, err = downloader.start_chunked_download(entry, files[idx], deps)
        if not handle then
            if has_progress then progress.close() end
            UIManager:show(InfoMessage:new{
                text = _("Download failed: ") .. tostring(err),
                timeout = 5,
            })
            return
        end

        -- Pump the coroutine on each UI tick
        local function pump()
            if state:is_cancelled() then
                handle:cancel()
                handle:finalize()
                if has_progress then progress.close() end
                UIManager:show(InfoMessage:new{ text = _("Download cancelled."), timeout = 3 })
                if has_navigator then
                    nav.pop()
                    UIManager:scheduleIn(0.1, function()
                        nav.push("detail", {
                            item = item,
                            on_download = function(b) self_ref:_onDownloadBook(b) end,
                            on_delete = function(b) self_ref:_onDeleteBook(b) end,
                        })
                    end)
                end
                return
            end

            local still_running = handle:pump()

            -- Update progress UI between chunks
            if has_progress then progress.update(state) end

            if still_running then
                -- Yield back to event loop, resume in 50ms.
                -- NOTE: Must use a positive delay, NOT 0!
                -- UIManager's handleInput() drains ALL due tasks in a
                -- repeat…until loop before processing input events.
                -- scheduleIn(0) makes the task "due now", so the drain
                -- loop never exits and cancel taps are never processed.
                -- 50ms gives the event loop time to process taps while
                -- still pumping ~20 chunks/sec (plenty for progress UI).
                UIManager:scheduleIn(0.05, pump)
            else
                -- Download finished for this file
                local ok, reason = handle:finalize()
                if not ok then
                    if has_progress then progress.close() end
                    UIManager:show(InfoMessage:new{
                        text = _("Download failed: ") .. tostring(reason),
                        timeout = 5,
                    })
                    return
                end

                -- Schedule next file (small delay to let event loop process input)
                UIManager:scheduleIn(0.05, function()
                    schedule_next(idx + 1)
                end)
            end
        end

        -- Start pumping (small delay to let event loop process input)
        UIManager:scheduleIn(0.05, pump)
    end

    UIManager:scheduleIn(0.1, function()
        schedule_next(1)
    end)
end

------------------------------------------------------------------------
-- Delete handler — removes downloaded files and manifest entry
-- @param item table  ABS item to delete
------------------------------------------------------------------------
function LibraryBrowserView:_onDeleteBook(item)
    abs_logger.info("Delete requested: " .. (item.title or item.id))
    if not has_manifest then
        UIManager:show(InfoMessage:new{ text = _("Delete not available") })
        return
    end
    manifest.init()
    -- Gap 4: Delete confirmation dialog
    UIManager:show(ConfirmBox:new{
        text = _("Delete this downloaded book?"),
        ok_text = _("Delete"),
        ok_callback = function()
            local lfs = _G.lfs or require("lfs")
            local fs = {
                delete_file = function(path) os.remove(path) end,
                delete_dir = function(path) lfs.rmdir(path) end,
            }
            local ok = downloader.delete_book(item.id, manifest, fs)
            if ok then
                UIManager:show(InfoMessage:new{ text = _("Book deleted successfully."), timeout = 3 })
            else
                UIManager:show(InfoMessage:new{ text = _("Book not found in downloads."), timeout = 3 })
            end
            -- Refresh detail view by popping and re-pushing
            if has_navigator then
                nav.pop()
                UIManager:scheduleIn(0.1, function()
                    nav.push("detail", {
                        item = item,
                        on_download = function(b) self:_onDownloadBook(b) end,
                        on_delete = function(b) self:_onDeleteBook(b) end,
                    })
                end)
            end
        end,
    })
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
    self.current_page = 1  -- reset to first page
    abs_logger.verbose("Sort cycled to: " .. next_sort)

    -- Re-render
    self:_refresh()
end

function LibraryBrowserView:onSearch()
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Search library"),
        input = self.search_query or "",
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
                        local query = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        browser.search(query)
                    end,
                },
            },
            {
                {
                    text = _("Clear search"),
                    callback = function()
                        UIManager:close(input_dialog)
                        browser.search("")
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end
------------------------------------------------------------------------
--- Public: prepare library data (data/render split)
--- Handles API config check, getLibraries, fetchAll, cover cache init.
--- @return table|nil  data ({library_id=...}) on success, nil on failure
--- @return table|nil  error_info ({type=..., message=...}) on failure, nil on success
------------------------------------------------------------------------
function browser.prepare()
    if not has_api or not api.is_configured() then
        return nil, { type = "config", message = "API not configured" }
    end

    local api_ok, data = api.getLibraries()
    local libraries = (data and data.libraries) or {}

    if not api_ok or #libraries == 0 then
        return nil, { type = "api", message = "No libraries found" }
    end

    local library_id = libraries[1].id

    local fetch_ok, fetch_err = library_store.fetchAll(library_id)
    if not fetch_ok then
        return nil, { type = "network", message = "Failed to load library", detail = fetch_err }
    end

    -- Initialize cover cache
    if has_cover_cache then
        local DataStorage = require("datastorage")
        local cache_dir = DataStorage:getSettingsDir() .. "/absaudio_covers"
        cover_cache.init(cache_dir)
    end

    return { library_id = library_id }
end

------------------------------------------------------------------------
--- Public: show library browser
--- Calls prepare() to fetch data, then renders the widget.
------------------------------------------------------------------------
function browser.show(data)
    data = data or {}
    _view = nil

    abs_logger.info("Opening library browser")

    local prep_data, err = browser.prepare()
    if not prep_data then
        abs_logger.warn("Library browser prepare failed: " .. (err and err.message or "unknown"))
        if err and err.type == "config" then
            -- nav.push detects nil return and auto-rolls back
            return nil
        elseif err and err.type == "api" then
            UIManager:show(InfoMessage:new{
                text = _("No libraries found. Check your server configuration."),
                timeout = 3,
            })
            return nil
        elseif err and err.type == "network" then
            UIManager:show(InfoMessage:new{
                text = _("Failed to load library. Check your connection."),
                timeout = 3,
            })
            return nil
        else
            -- Unexpected error
            UIManager:show(InfoMessage:new{
                text = _("Error loading library: ") .. tostring(err and err.message or "unknown"),
                timeout = 5,
            })
            return nil
        end
    end

    -- Data ready — render the widget (pcall for widget creation errors)
    local ok, render_err = pcall(function()
        _view = LibraryBrowserView:new{
            current_page = 1,
            search_query = "",
        }
        UIManager:show(_view)
    end)

    if not ok then
        abs_logger.warn("Library browser render failed: " .. tostring(render_err))
        UIManager:show(InfoMessage:new{
            text = _("Error rendering library: ") .. tostring(render_err),
            timeout = 5,
        })
        return nil
    end

    -- Schedule batch cover fetch + refresh for current page
    if has_cover_cache then
        browser._scheduleCoverFetch()
    end

    return _view
end

------------------------------------------------------------------------
-- Batch cover fetch for current page items
------------------------------------------------------------------------
function browser._scheduleCoverFetch()
    -- Fetch covers for ALL library items, not just current page.
    -- Covers are persistently cached so this only downloads missing ones.
    UIManager:scheduleIn(0.5, function()
        if not _view then return end

        -- Get the full library (all pages, no pagination)
        local result = library_store.getItems({
            page = 1,
            per_page = 9999,  -- all items
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

--- Clear all cached cover images
function browser.clearCoverCache()
    local DataStorage = require("datastorage")
    local cache_dir = DataStorage:getSettingsDir() .. "/absaudio_covers"
    local lfs = _G.lfs or require("lfs")

    if lfs.attributes(cache_dir, "mode") ~= "directory" then
        return 0
    end

    local count = 0
    for file in lfs.dir(cache_dir) do
        if file:match("%.jpg$") then
            local path = cache_dir .. "/" .. file
            os.remove(path)
            count = count + 1
        end
    end

    abs_logger.info("Cleared " .. count .. " cached covers")
    return count
end

--- Get current browser state (for testing and external inspection)
-- @return table  { search_query, current_page }
function browser.getState()
    if _view then
        return {
            search_query = _view.search_query or "",
            current_page = _view.current_page or 1,
        }
    end
    return {
        search_query = "",
        current_page = 1,
    }
end

--- Get reference to current view instance (for testing)
function browser._getView()
    return _view
end

--- Search the library by query string
--- Sets the search query, resets to page 1, and refreshes the view.
--- @param query string  search text (empty string clears the search)
function browser.search(query)
    if _view then
        _view.search_query = query or ""
        _view.current_page = 1
        abs_logger.verbose("Search: query='" .. _view.search_query .. "'")
        _view:_refresh()
    end
end

return browser
