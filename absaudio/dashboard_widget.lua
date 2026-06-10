-- Dashboard widget for absaudio.koplugin
-- Root view with 4 sections: Resume Last Book, Downloaded Books, Browse Library, Settings
-- Reads real data from manifest and API modules.
--
-- Public API:
--   dashboard.prepare()  — fetch data, returns (data, nil) or (nil, error_info)
--   dashboard.show()     — display the dashboard

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

local config = require("config")
local abs_logger = require("abs_logger")
local error_handler = require("error_handler")
local widget_helpers = require("absaudio/widget_helpers")

-- Try to load manifest and api
local has_manifest, manifest = pcall(require, "manifest")
local has_api, api = pcall(require, "api")
local has_library_browser, library_browser = pcall(require, "absaudio/library_browser")
if not has_library_browser then
    -- Use print() so it always shows in crash.log / stdout
    print("[ABS-DEBUG] library_browser load FAILED: " .. tostring(library_browser))
end

local has_library_store, library_store = pcall(require, "absaudio/library_store")
local has_navigator, nav = pcall(require, "absaudio/navigator")
local has_cover_cache, cover_cache = pcall(require, "absaudio/cover_cache")
local has_downloader, downloader = pcall(require, "absaudio/downloader")
local has_abs_config, abs_config = pcall(require, "absaudio/config")
local has_progress, progress = pcall(require, "absaudio/download_progress")

local dashboard = {}

------------------------------------------------------------------------
-- Public: prepare dashboard data (pure data, no widgets)
------------------------------------------------------------------------
function dashboard.prepare()
    -- Initialize manifest if available
    if has_manifest then
        manifest.init()
    end

    -- If manifest is not available, return error
    if not has_manifest then
        return nil, { type = "manifest", message = "Manifest module not available" }
    end

    local recent_book = manifest.getRecentBook()
    local all_books = manifest.getAllBooks()

    return {
        recent_book = recent_book,
        all_books = all_books or {},
    }, nil
end


------------------------------------------------------------------------
-- Helper: format progress as percentage
------------------------------------------------------------------------
local function format_progress(current_time, duration)
    if not duration or duration <= 0 then return "0%" end
    local pct = math.floor((current_time or 0) / duration * 100)
    return tostring(pct) .. "%"
end

------------------------------------------------------------------------
-- Dashboard View
------------------------------------------------------------------------
local DashboardView = FocusManager:extend{
    name = "absaudio_dashboard",
    is_editable = false,
    title = "ABS Audio",
    covers_fullscreen = true, -- hint for UIManager:_repaint()
}

function DashboardView:init()
    -- Callbacks are already set on self by the constructor (via dashboard.show)
    -- Store reference for tap callbacks
    self.dashboard_ref = self

    -- Back key closes the dashboard
    if Device:hasKeys() then
        self.key_events = self.key_events or {}
        self.key_events.Close = { { Device.input.group.Back } }
    end

    -- Swipe down closes the dashboard
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

    -- Initialize cover cache for thumbnail rendering
    if has_cover_cache and not cover_cache.isInitialized() then
        local DataStorage = require("datastorage")
        cover_cache.init(DataStorage:getSettingsDir() .. "/absaudio_covers")
    end

    -- Build the dashboard content
    self.content_group = VerticalGroup:new{ align = "left" }

    -- Add top padding so content isn't flush against the very top
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.large })

    -- Title
    self:_addTitle()

    -- Resume Last Book section
    self:_addResumeSection()

    -- Separator
    widget_helpers.addSeparator(self.content_group, self.content_width)

    -- Downloaded Books section
    self:_addDownloadedBooksSection()

    -- Separator
    widget_helpers.addSeparator(self.content_group, self.content_width)

    -- Browse Library button
    self:_addBrowseLibraryButton()

    -- Separator
    widget_helpers.addSeparator(self.content_group, self.content_width)

    -- Settings section
    self:_addSettingsSection()

    -- Wrap content in a scrollable container
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

    -- Handle back key / tap outside
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end

    -- Swipe/pan to scroll is handled by ScrollableContainer
    -- Tap outside to close
    self.ges_events.TapClose = {
        GestureRange:new{
            ges = "tap",
            range = Geom:new{
                x = 0, y = 0,
                w = self.screen_width,
                h = self.screen_height,
            },
        },
    }
end

function DashboardView:_addTitle()
    local title = TextWidget:new{
        text = self.title,
        face = Font:getFace("tfont", 26),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    table.insert(self.content_group, CenterContainer:new{
        dimen = Geom:new{ w = self.content_width, h = title:getSize().h },
        title,
    })
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.large })
end

function DashboardView:_addResumeSection()
    -- Section header
    local header = TextWidget:new{
        text = _("Resume Last Book"),
        face = Font:getFace("cfont", 18),
        bold = true,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }
    table.insert(self.content_group, header)
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })

    -- Get most recently played book from prepared data
    local recent_book = nil
    if self.dashboard_data then
        recent_book = self.dashboard_data.recent_book
    end

    if recent_book and recent_book.current_time and recent_book.current_time > 0 then
        -- Show book info with resume button
        local progress_text = format_progress(recent_book.current_time, recent_book.duration)
            .. " · " .. widget_helpers.format_duration(recent_book.current_time)
            .. " / " .. widget_helpers.format_duration(recent_book.duration)

        local info_text = string.format("%s\n%s\n%s\n▶ Resume",
            recent_book.title or "Unknown",
            recent_book.author or "",
            progress_text)

        local book_row = self:_buildBookRow(recent_book, info_text)

        -- Wrap in a tappable container
        local tap_container = InputContainer:new{
            dimen = Geom:new{
                w = self.content_width,
                h = Screen:scaleBySize(100) + 2 * Size.padding.small,
            },
        }
        tap_container.ges_events.TapResume = {
            GestureRange:new{
                ges = "tap",
                range = tap_container.dimen,
            },
        }
        tap_container.dashboard_ref = self.dashboard_ref
        local book = recent_book  -- capture for closure
        function tap_container:onTapResume()
            self.dashboard_ref:_onResumeBook(book)
            return true
        end
        tap_container[1] = book_row
        table.insert(self.content_group, tap_container)
    else
        local empty = TextWidget:new{
            text = _("No audiobooks played yet."),
            face = Font:getFace("cfont", 14),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
        table.insert(self.content_group, empty)
    end

    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.default })
end

--- Build a book row widget: [cover thumbnail 80×100] [padding] [title + progress text]
-- Matches library browser's _addBookRow layout for visual consistency.
function DashboardView:_buildBookRow(book, title_text)
    local thumb_width = Screen:scaleBySize(80)
    local thumb_height = Screen:scaleBySize(100)

    -- Resolve cover image or placeholder
    local cover_widget
    local cover_path = nil
    if has_cover_cache and book.abs_item_id then
        if cover_cache.hasCachedCover(book.abs_item_id) then
            cover_path = cover_cache.getCoverPath(book.abs_item_id)
        end
    end

    if cover_path then
        cover_widget = ImageWidget:new{
            file = cover_path,
            width = thumb_width,
            height = thumb_height,
            scale_factor = 0,
        }
    else
        -- Gray placeholder matching library browser fallback
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

    -- Text area: title + author + progress
    local text_area_width = self.content_width - thumb_width - Size.padding.default
    local info_widget = TextBoxWidget:new{
        text = title_text,
        face = Font:getFace("cfont", 14),
        width = text_area_width,
    }

    -- Assemble: [cover] [padding] [text]
    return HorizontalGroup:new{
        align = "center",
        cover_widget,
        HorizontalSpan:new{ width = Size.padding.default },
        LeftContainer:new{
            dimen = Geom:new{ w = text_area_width, h = thumb_height },
            info_widget,
        },
    }
end

function DashboardView:_addDownloadedBooksSection()
    -- Section header
    local header = TextWidget:new{
        text = _("Downloaded Books"),
        face = Font:getFace("cfont", 18),
        bold = true,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }
    table.insert(self.content_group, header)
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })

    -- Get all books from prepared data
    local books = {}
    if self.dashboard_data and self.dashboard_data.all_books then
        books = self.dashboard_data.all_books
    end

    if #books == 0 then
        local empty = TextBoxWidget:new{
            text = _("No audiobooks downloaded yet.\nUse Browse Library to find and download books."),
            face = Font:getFace("cfont", 14),
            width = self.content_width,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
        table.insert(self.content_group, empty)
    else
        -- Show up to 10 books with progress badges
        local max_show = math.min(#books, 10)
        for i = 1, max_show do
            local book = books[i]
            local progress_text = ""
            if book.is_finished then
                progress_text = "✓ Finished"
            elseif book.duration and book.duration > 0 then
                progress_text = format_progress(book.current_time, book.duration)
                    .. " · " .. widget_helpers.format_duration(book.current_time or 0)
                    .. " / " .. widget_helpers.format_duration(book.duration)
            else
                progress_text = _("Not started")
            end

            -- Check for incomplete downloads
            local has_incomplete = false
            if book.files then
                for _, f in ipairs(book.files) do
                    if f.status == "partial" or f.status == "pending" then
                        has_incomplete = true
                        break
                    end
                end
            end

            local badge = has_incomplete and " ⚠ Resume download" or ""
            local title_text = (book.title or "Unknown") .. "\n  " .. progress_text .. badge

            local book_row = self:_buildBookRow(book, title_text)

            -- Wrap in tappable container to navigate to book detail
            local tap_container = InputContainer:new{
                dimen = Geom:new{
                    w = self.content_width,
                    h = Screen:scaleBySize(100) + Size.padding.small,
                },
            }
            tap_container.ges_events.TapBook = {
                GestureRange:new{
                    ges = "tap",
                    range = tap_container.dimen,
                },
            }
            tap_container.dashboard_ref = self.dashboard_ref
            tap_container.book = book
            function tap_container:onTapBook()
                self.dashboard_ref:_onBookTap(self.book)
                return true
            end
            tap_container[1] = book_row
            table.insert(self.content_group, tap_container)
            table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })
        end

        if #books > max_show then
            local more = TextWidget:new{
                text = string.format(_("... and %d more"), #books - max_show),
                face = Font:getFace("cfont", 13),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            }
            table.insert(self.content_group, more)
        end
    end

    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.default })
end

function DashboardView:_addBrowseLibraryButton()
    -- Check if we should grey out the button
    local is_greyed = false
    local grey_reason = ""
    if not has_api or not api.is_configured() then
        is_greyed = true
        grey_reason = _("Configure server settings first")
    elseif has_library_store and library_store.wasLastFetchSuccessful() == false then
        is_greyed = true
        grey_reason = _("Connect to WiFi to browse")
    end

    local btn_text = _("Browse Library")
    if is_greyed then
        btn_text = _("Browse Library") .. "\n" .. grey_reason
    end

    local btn = TextWidget:new{
        text = btn_text,
        face = Font:getFace("cfont", 16),
        fgcolor = is_greyed and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLUE,
    }

    local tap_container = InputContainer:new{
        dimen = Geom:new{
            w = self.content_width,
            h = btn:getSize().h + Size.padding.default,
        },
    }

    if not is_greyed then
        tap_container.ges_events.TapBrowse = {
            GestureRange:new{
                ges = "tap",
                range = tap_container.dimen,
            },
        }
        tap_container.dashboard_ref = self.dashboard_ref
        function tap_container:onTapBrowse()
            self.dashboard_ref:_onBrowseLibrary()
            return true
        end
    end

    tap_container[1] = btn
    table.insert(self.content_group, tap_container)
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.default })
end

function DashboardView:_addSettingsSection()
    -- Section header
    local header = TextWidget:new{
        text = _("Settings"),
        face = Font:getFace("cfont", 18),
        bold = true,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }
    table.insert(self.content_group, header)
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })

    -- Config dialog button
    self:_addActionButton(_("⚙ Server & Token"), function()
        self.dashboard_ref:_onOpenSettings()
    end)

    -- Sync Now button stub
    self:_addActionButton(_("↻ Sync Now"), function()
        self.dashboard_ref:_onSyncNow()
    end)

    -- Export Diagnostics button stub
    self:_addActionButton(_("📋 Export Diagnostics"), function()
        self.dashboard_ref:_onExportDiagnostics()
    end)

    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.default })
end

function DashboardView:_addActionButton(label_text, callback)
    local btn = TextWidget:new{
        text = label_text,
        face = Font:getFace("cfont", 16),
        fgcolor = Blitbuffer.COLOR_BLUE,
    }

    local tap_container = InputContainer:new{
        dimen = Geom:new{
            w = self.content_width,
            h = btn:getSize().h + Size.padding.default,
        },
    }
    tap_container.ges_events.TapAction = {
        GestureRange:new{
            ges = "tap",
            range = tap_container.dimen,
        },
    }
    tap_container.dashboard_ref = self.dashboard_ref
    function tap_container:onTapAction()
        callback()
        return true
    end
    tap_container[1] = btn
    table.insert(self.content_group, tap_container)
end


-- Actions

function DashboardView:_onResumeBook(book)
    abs_logger.info("Resume book: " .. (book.title or "unknown"))
    -- Stub — full playback integration in later slice
    UIManager:show(InfoMessage:new{
        text = string.format(_("Resume: %s\nPosition: %s / %s"),
            book.title or "Unknown",
            widget_helpers.format_duration(book.current_time),
            widget_helpers.format_duration(book.duration)),
        timeout = 3,
    })
end

function DashboardView:_onBrowseLibrary()
    abs_logger.info("Browse Library tapped")
    if not has_api or not api.is_configured() then
        error_handler.show("auth", "Configure your server settings first.")
        return
    end
    if not has_library_browser then
        UIManager:show(InfoMessage:new{
            text = _("Library browser not available."),
            timeout = 3,
        })
        return
    end
    if has_navigator then
        nav.push("browser", {})
    end
end

function DashboardView:_onOpenSettings()
    abs_logger.info("Settings tapped from dashboard")
    if self.on_settings then
        -- Close dashboard first, then open settings
        self:onClose()
        -- Schedule settings to open after dashboard closes
        local settings_cb = self.on_settings
        UIManager:scheduleIn(0.2, function()
            settings_cb()
        end)
    else
        UIManager:show(InfoMessage:new{
            text = _("Settings not available. Open from Menu → Plugins → ABS Audio → Settings."),
            timeout = 5,
        })
    end
end

function DashboardView:_onSyncNow()
    abs_logger.info("Sync Now tapped")
    if self.on_sync_now then
        self.on_sync_now()
    else
        UIManager:show(InfoMessage:new{
            text = _("Sync will be available in a future update."),
            timeout = 3,
        })
    end
end

function DashboardView:_onExportDiagnostics()
    abs_logger.info("Export Diagnostics tapped")
    if self.on_export_diagnostics then
        self.on_export_diagnostics()
    else
        UIManager:show(InfoMessage:new{
            text = _("Export Diagnostics will be available in a future update."),
            timeout = 3,
        })
    end
end

function DashboardView:_onBookTap(book)
    abs_logger.info("Book tapped from dashboard: " .. (book.title or "unknown"))
    if has_navigator then
        -- Build a rich item from manifest data so detail view can show all sections.
        local detail_item = {
            id = book.abs_item_id,
            title = book.title,
            author = book.author,
            duration = book.duration or 0,
            chapters = book.chapters or {},
            files = book.files,
            local_dir = book.local_dir,
            media = {
                duration = book.duration or 0,
                chapters = book.chapters or {},
            },
        }
        if book.audioFiles then detail_item.audioFiles = book.audioFiles end
        if book.ebookFiles then detail_item.ebookFiles = book.ebookFiles end
        if book.media and book.media.ebookFile then
            detail_item.media.ebookFile = book.media.ebookFile
        end

        nav.push("detail", {
            item = detail_item,
            on_download = function(data)
                local book_item = data.item or data
                local ebook_only = data.ebook_only or false
                self:_onDownloadBook(book_item, ebook_only)
            end,
            on_delete = function(data)
                local book_item = data.item or data
                local ebook_only = data.ebook_only or false
                self:_onDeleteBook(book_item, ebook_only)
            end,
            on_open_ebook = function(filepath)
                self:_onOpenEbook(filepath)
            end,
        })
    end
end

------------------------------------------------------------------------
-- Download handler — mirrors library_browser:_onDownloadBook
-- Uses correct API: downloader.prepare_download + start_chunked_download
------------------------------------------------------------------------
function DashboardView:_onDownloadBook(item, ebook_only)
    abs_logger.info("Dashboard download requested: " .. (item.title or item.id)
        .. (ebook_only and " (ebook)" or ""))
    if not has_manifest or not has_config or not has_downloader then
        UIManager:show(InfoMessage:new{ text = _("Download not available") })
        return
    end
    manifest.init()

    local result = nil
    if ebook_only then
        local ok, ebook_result = downloader.prepare_ebook_download(item, manifest, config)
        if not ok then
            UIManager:show(InfoMessage:new{
                text = _("No ebook files found for this book."),
                timeout = 3,
            })
            return
        end
        result = ebook_result
    else
        local existing_entry = manifest.getBook(item.id)
        if existing_entry and manifest.hasIncompleteFiles(item.id) then
            abs_logger.info("Resuming incomplete download: " .. (item.title or item.id))
            result = existing_entry
        else
            local ok, prepare_result = downloader.prepare_download(item, manifest, config)
            if not ok then
                if prepare_result == "already_downloaded" then
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
            result = prepare_result
        end
    end

    -- Free space check
    local total_sizes = downloader.calculate_download_size(result.files)
    local needed = total_sizes
    if needed > 0 then
        local download_dir = abs_config.get("download_dir") or "/tmp"
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

    -- Download pipeline with progress widget
    local state = downloader.create_download_state()
    state.start_time = os.time()
    state.total_files = #result.files
    state.total_bytes = total_sizes

    if has_progress then
        progress.show({
            state = state,
            on_cancel = function() state:cancel() end,
        })
    end

    local lfs = _G.lfs or require("lfs")
    local deps = {
        manifest = manifest,
        api = require("absaudio/api"),
        fs = {
            mkdir = function(path)
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
            open = function(path, mode) return io.open(path, mode) end,
            get_file_size = function(path)
                local attr = lfs.attributes(path)
                return attr and attr.size or nil
            end,
        },
        state = state,
    }

    local files_to_download = downloader.select_files_to_download(result.files)
    local entry = result
    local self_ref = self

    local function schedule_next(idx)
        if idx > #files_to_download or state:is_cancelled() then
            if has_progress then progress.close() end

            local msg = state:is_cancelled()
                and _("Download cancelled.")
                or _("Download complete!")
            UIManager:show(InfoMessage:new{ text = msg, timeout = 3 })

            -- Refresh detail view
            if has_navigator then
                nav.pop()
                UIManager:scheduleIn(0.1, function()
                    nav.push("detail", {
                        item = item,
                        on_download = function(data)
                            local bi = data.item or data
                            local eo = data.ebook_only or false
                            self_ref:_onDownloadBook(bi, eo)
                        end,
                        on_delete = function(data)
                            local bi = data.item or data
                            local eo = data.ebook_only or false
                            self_ref:_onDeleteBook(bi, eo)
                        end,
                        on_open_ebook = function(fp) self_ref:_onOpenEbook(fp) end,
                    })
                end)
            end
            return
        end

        local file = files_to_download[idx]
        state.current_file = file.filename
        state.current_file_index = idx

        -- Use correct API: start_chunked_download(entry, file, deps)
        downloader.start_chunked_download(entry, file, deps)
    end

    UIManager:scheduleIn(0.05, function() schedule_next(1) end)
end

------------------------------------------------------------------------
-- Delete handler — mirrors library_browser:_onDeleteBook
------------------------------------------------------------------------
function DashboardView:_onDeleteBook(item, ebook_only)
    abs_logger.info("Dashboard delete requested: " .. (item.title or item.id)
        .. (ebook_only and " (ebook only)" or ""))
    if not has_manifest or not has_downloader then
        UIManager:show(InfoMessage:new{ text = _("Delete not available") })
        return
    end
    manifest.init()

    if ebook_only then
        self:_onDeleteEbookOnly(item)
        return
    end

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
            -- Refresh detail view
            if has_navigator then
                nav.pop()
                UIManager:scheduleIn(0.1, function()
                    nav.push("detail", {
                        item = item,
                        on_download = function(data)
                            local bi = data.item or data
                            local eo = data.ebook_only or false
                            self_ref:_onDownloadBook(bi, eo)
                        end,
                        on_delete = function(data)
                            local bi = data.item or data
                            local eo = data.ebook_only or false
                            self_ref:_onDeleteBook(bi, eo)
                        end,
                        on_open_ebook = function(fp) self_ref:_onOpenEbook(fp) end,
                    })
                end)
            end
        end,
    })
end

------------------------------------------------------------------------
-- Ebook-only delete helper
------------------------------------------------------------------------
function DashboardView:_onDeleteEbookOnly(item)
    local entry = manifest.getBook(item.id)
    if not entry then return end

    local lfs = _G.lfs or require("lfs")
    for _, f in ipairs(entry.files or {}) do
        if f.type == "ebook" then
            local path = entry.local_dir .. "/" .. f.filename
            if lfs.attributes(path) then
                os.remove(path)
            end
            f.status = nil
        end
    end
    manifest.flush()
    UIManager:show(InfoMessage:new{ text = _("Ebook deleted."), timeout = 2 })

    if has_navigator then
        nav.pop()
        UIManager:scheduleIn(0.1, function()
            nav.push("detail", {
                item = item,
                on_download = function(data)
                    local bi = data.item or data
                    local eo = data.ebook_only or false
                    self:_onDownloadBook(bi, eo)
                end,
                on_delete = function(data)
                    local bi = data.item or data
                    local eo = data.ebook_only or false
                    self_ref:_onDeleteBook(bi, eo)
                end,
                on_open_ebook = function(fp) self_ref:_onOpenEbook(fp) end,
            })
        end)
    end
end

------------------------------------------------------------------------
-- Open ebook in KOReader's ReaderUI — mirrors library_browser:_onOpenEbook
------------------------------------------------------------------------
function DashboardView:_onOpenEbook(filepath)
    abs_logger.info("Dashboard opening ebook: " .. tostring(filepath))
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(filepath)
end

function DashboardView:onClose()
end

function DashboardView:onSwipe(arg, ges_ev)
    if ges_ev.direction == "south" then
        self:onClose()
    end
    return true
end

function DashboardView:onTapClose()
    -- Only close if tap is outside the content area (we let ScrollableContainer handle inside taps)
    -- For now, use back key to close
    return false
end

------------------------------------------------------------------------
-- Public: show the dashboard
------------------------------------------------------------------------
function dashboard.show(data)
    data = data or {}
    abs_logger.info("Showing dashboard")

    -- Prepare data (pure data, no widgets)
    local prepared, err = dashboard.prepare()
    if err then
        abs_logger.warn("dashboard.prepare() failed: " .. tostring(err.message))
    end

    -- Pass prepared data + callbacks through constructor
    local view = DashboardView:new{
        dashboard_data = prepared or {},
        on_settings = data.on_settings,
        on_sync_now = data.on_sync_now,
        on_export_diagnostics = data.on_export_diagnostics,
    }
    UIManager:show(view)
    return view
end

return dashboard
