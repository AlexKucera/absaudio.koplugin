-- Book detail view widget for absaudio.koplugin
-- Fullscreen scrollable view showing cover art, metadata, audio/ebook files,
-- and chapter list for a single library item.
--
-- Public API:
--   detail.show(data)
--     data: { item=..., on_download=fn }
--
-- When show() is called, it first tries to fetch expanded item details from ABS.
-- If that fails and the book is downloaded, it falls back to manifest data.
-- If that fails and the book is not downloaded, it shows an error.

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
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
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

-- Try to load dependencies
local has_manifest, manifest = pcall(require, "manifest")
local has_api, api = pcall(require, "api")
local has_cover_cache, cover_cache = pcall(require, "absaudio/cover_cache")
local library_store = require("absaudio/library_store")
local has_navigator, nav = pcall(require, "absaudio/navigator")

local detail = {}

------------------------------------------------------------------------
-- Public: prepare item data for rendering
-- Fetches expanded details from API, falls back to manifest,
-- or returns basic item data. Returns (data, nil) or (nil, error_info).
------------------------------------------------------------------------
function detail.prepare(item)
    -- Initialize manifest for potential fallback
    if has_manifest then
        manifest.init()
    end

    -- Try API first if configured
    if has_api and api.is_configured() then
        local ok, expanded = api.getItemDetails(item.id)
        if ok then
            return detail._mergeItemData(item, expanded), nil
        end
        abs_logger.warn("Failed to fetch item details via API, trying fallback")
    end

    -- Try manifest fallback
    if has_manifest then
        local book = manifest.getBook(item.id)
        if book then
            return detail._itemFromManifest(item, book), nil
        end
    end

    -- Return basic item data if it has enough info
    if item.title or item.media then
        abs_logger.info("prepare: returning basic item data (no API or manifest)")
        return item, nil
    end

    -- Nothing available
    return nil, { type = "network", message = _("Connect to WiFi to view book details.") }
end





------------------------------------------------------------------------
-- Helper: get duration from item
------------------------------------------------------------------------
local function get_item_duration(item)
    if item.media and item.media.duration then
        return item.media.duration
    end
    return item.duration or 0
end

------------------------------------------------------------------------
-- Helper: check if a format is the preferred format
------------------------------------------------------------------------
local function is_preferred_format(format)
    local preferred = config.get("preferred_format") or "m4b"
    return format and format:lower() == preferred:lower()
end

------------------------------------------------------------------------
-- Book Detail View
------------------------------------------------------------------------
local BookDetailView = FocusManager:extend{
    name = "absaudio_book_detail",
    is_editable = false,
    covers_fullscreen = true,
}

function BookDetailView:init()
    -- Store reference for tap callbacks
    self.detail_ref = self

    -- Back key closes the detail view
    if Device:hasKeys() then
        self.key_events = self.key_events or {}
        self.key_events.Close = { { Device.input.group.Back } }
    end

    -- Swipe down closes the detail view
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

    -- Back button header
    self:_addBackHeader()

    -- Cover art
    self:_addCoverArt()

    -- Metadata section
    self:_addMetadata()

    -- Download status badge
    self:_addDownloadStatus()

    widget_helpers.addSeparator(self.content_group, self.content_width)

    -- Audio files section
    local audio_files = self.item.audioFiles or {}
    if #audio_files > 0 then
        self:_addAudioFiles(audio_files)
        widget_helpers.addSeparator(self.content_group, self.content_width)
    end

    -- Ebook/PDF files section
    local ebook_files = self.item.ebookFiles or {}
    if #ebook_files > 0 then
        self:_addEbookFiles(ebook_files)
        widget_helpers.addSeparator(self.content_group, self.content_width)
    end

    -- Chapters section
    local chapters = {}
    if self.item.media and self.item.media.chapters then
        chapters = self.item.media.chapters
    end
    if #chapters > 0 then
        self:_addChapters(chapters)
    end

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
-- Header with back button
------------------------------------------------------------------------
function BookDetailView:_addBackHeader()
    local back_text = TextWidget:new{
        text = "← " .. _("Back"),
        face = Font:getFace("cfont", 16),
        fgcolor = Blitbuffer.COLOR_BLUE,
    }

    local tap_container = InputContainer:new{
        dimen = Geom:new{
            w = self.content_width,
            h = back_text:getSize().h + Size.padding.default,
        },
    }
    tap_container.ges_events.TapBack = {
        GestureRange:new{
            ges = "tap",
            range = tap_container.dimen,
        },
    }
    tap_container.detail_ref = self.detail_ref
    function tap_container:onTapBack()
        self.detail_ref:onClose()
        return true
    end
    tap_container[1] = back_text
    table.insert(self.content_group, tap_container)
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })
end

------------------------------------------------------------------------
-- Cover art section
------------------------------------------------------------------------
function BookDetailView:_addCoverArt()
    local item_id = self.item.id
    local cover_path = nil

    -- Try to find cover: first check manifest (downloaded books), then cover cache
    if has_manifest then
        manifest.init()
        local book = manifest.getBook(item_id)
        if book and book.local_dir then
            cover_path = book.local_dir .. "/cover.jpg"
        end
    end

    if not cover_path and has_cover_cache then
        if cover_cache.hasCachedCover(item_id) then
            cover_path = cover_cache.getCoverPath(item_id)
        end
    end

    if cover_path then
        local cover_widget = ImageWidget:new{
            file = cover_path,
            width = self.content_width,
            height = math.min(200, self.screen_height * 0.25),
            scale_factor = 0,
            -- If the image fails to load, we show nothing (graceful degradation)
        }
        -- Center the cover image
        local cover_h = 200
        table.insert(self.content_group, CenterContainer:new{
            dimen = Geom:new{ w = self.content_width, h = cover_h },
            cover_widget,
        })
    else
        -- Placeholder for missing cover
        local placeholder = FrameContainer:new{
            width = self.content_width,
            height = 80,
            background = Blitbuffer.COLOR_LIGHT_GRAY,
            bordersize = 0,
            padding = 0,
            CenterContainer:new{
                dimen = Geom:new{ w = self.content_width, h = 80 },
                TextWidget:new{
                    text = _("No Cover"),
                    face = Font:getFace("cfont", 16),
                    fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                },
            },
        }
        table.insert(self.content_group, placeholder)
    end

    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.default })
end

------------------------------------------------------------------------
-- Metadata section: title, author, duration
------------------------------------------------------------------------
function BookDetailView:_addMetadata()
    local title = library_store.getItemTitle(self.item)
    local author = library_store.getItemAuthor(self.item)
    local duration = get_item_duration(self.item)

    -- Title
    local title_widget = TextWidget:new{
        text = title,
        face = Font:getFace("tfont", 22),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
        max_width = self.content_width,
    }
    table.insert(self.content_group, title_widget)
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })

    -- Author
    if author and author ~= "" then
        local author_widget = TextWidget:new{
            text = author,
            face = Font:getFace("cfont", 16),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            max_width = self.content_width,
        }
        table.insert(self.content_group, author_widget)
        table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })
    end

    -- Duration
    if duration and duration > 0 then
        local duration_widget = TextWidget:new{
            text = "⏱ " .. widget_helpers.format_duration(duration),
            face = Font:getFace("cfont", 14),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
        table.insert(self.content_group, duration_widget)
    end

    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.default })
end

------------------------------------------------------------------------
-- Download status badge
------------------------------------------------------------------------
function BookDetailView:_addDownloadStatus()
    local item_id = self.item.id
    local is_downloaded = false

    if has_manifest then
        local book = manifest.getBook(item_id)
        if book then
            is_downloaded = true
        end
    end

    if is_downloaded then
        local badge = TextWidget:new{
            text = "✓ " .. _("Downloaded"),
            face = Font:getFace("cfont", 14),
            fgcolor = Blitbuffer.COLOR_DARK_GREEN,
        }
        table.insert(self.content_group, badge)
    else
        local badge = TextWidget:new{
            text = _("Not downloaded"),
            face = Font:getFace("cfont", 14),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
        table.insert(self.content_group, badge)

        -- Show download button if callback provided
        if self.on_download then
            table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })
            local download_btn = TextWidget:new{
                text = _("⬇ Download"),
                face = Font:getFace("cfont", 16),
                fgcolor = Blitbuffer.COLOR_BLUE,
            }
            local tap_container = InputContainer:new{
                dimen = Geom:new{
                    w = self.content_width,
                    h = download_btn:getSize().h + Size.padding.default,
                },
            }
            tap_container.ges_events.TapDownload = {
                GestureRange:new{
                    ges = "tap",
                    range = tap_container.dimen,
                },
            }
            tap_container.detail_ref = self.detail_ref
            local item = self.item
            local on_download_cb = self.on_download
            function tap_container:onTapDownload()
                if on_download_cb then
                    on_download_cb(item)
                end
                return true
            end
            tap_container[1] = download_btn
            table.insert(self.content_group, tap_container)
        end
    end

    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })
end

------------------------------------------------------------------------
-- Section header helper
------------------------------------------------------------------------
function BookDetailView:_addSectionHeader(text)
    local header = TextWidget:new{
        text = text,
        face = Font:getFace("cfont", 18),
        bold = true,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }
    table.insert(self.content_group, header)
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })
end

------------------------------------------------------------------------
-- Audio files section
------------------------------------------------------------------------
function BookDetailView:_addAudioFiles(audio_files)
    self:_addSectionHeader(_("Audio Files"))

    local preferred = config.get("preferred_format") or "m4b"

    -- Sort: preferred format files first
    local sorted_files = {}
    for _, f in ipairs(audio_files) do
        table.insert(sorted_files, f)
    end
    table.sort(sorted_files, function(a, b)
        local a_pref = (a.format and a.format:lower() == preferred:lower()) and 0 or 1
        local b_pref = (b.format and b.format:lower() == preferred:lower()) and 0 or 1
        if a_pref ~= b_pref then return a_pref < b_pref end
        return (a.filename or "") < (b.filename or "")
    end)

    for _, file in ipairs(sorted_files) do
        local format_str = string.upper(file.format or "???")
        local is_preferred = is_preferred_format(file.format)
        local badge_color = is_preferred and Blitbuffer.COLOR_DARK_GREEN or Blitbuffer.COLOR_DARK_GRAY
        local badge_prefix = is_preferred and "★ " or ""

        local file_text = string.format("  %s%s  %s  %s",
            badge_prefix,
            format_str,
            file.filename or _("Unknown file"),
            widget_helpers.format_file_size(file.size))

        local file_widget = TextWidget:new{
            text = file_text,
            face = Font:getFace("cfont", 14),
            fgcolor = badge_color,
            max_width = self.content_width,
        }
        table.insert(self.content_group, file_widget)
        table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })
    end

    -- Show note about preferred format
    local note = TextWidget:new{
        text = string.format(_("★ = preferred format (%s)"), preferred),
        face = Font:getFace("cfont", 12),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }
    table.insert(self.content_group, note)
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.default })
end

------------------------------------------------------------------------
-- Ebook/PDF files section
------------------------------------------------------------------------
function BookDetailView:_addEbookFiles(ebook_files)
    self:_addSectionHeader(_("Ebook / PDF Files"))

    for _, file in ipairs(ebook_files) do
        local format_str = string.upper(file.format or "???")
        local file_text = string.format("  %s  %s  %s",
            format_str,
            file.filename or _("Unknown file"),
            widget_helpers.format_file_size(file.size))

        local file_widget = TextWidget:new{
            text = file_text,
            face = Font:getFace("cfont", 14),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            max_width = self.content_width,
        }
        table.insert(self.content_group, file_widget)
        table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })
    end

    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.default })
end

------------------------------------------------------------------------
-- Chapters section (tappable table of contents)
------------------------------------------------------------------------
function BookDetailView:_addChapters(chapters)
    self:_addSectionHeader(_("Chapters"))

    for i, chapter in ipairs(chapters) do
        local chapter_title = chapter.title or string.format(_("Chapter %d"), i)
        local time_range = widget_helpers.format_time(chapter.start or 0) .. " → " .. widget_helpers.format_time(chapter["end"] or 0)

        local chapter_text = string.format("  %s\n    %s", chapter_title, time_range)

        local chapter_widget = TextBoxWidget:new{
            text = chapter_text,
            face = Font:getFace("cfont", 14),
            width = self.content_width,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }

        -- Wrap in tappable container (for future seek-to-chapter)
        local tap_container = InputContainer:new{
            dimen = Geom:new{
                w = self.content_width,
                h = chapter_widget:getSize().h,
            },
        }
        tap_container.ges_events.TapChapter = {
            GestureRange:new{
                ges = "tap",
                range = tap_container.dimen,
            },
        }
        tap_container.detail_ref = self.detail_ref
        tap_container.chapter = chapter
        tap_container.chapter_idx = i
        function tap_container:onTapChapter()
            -- Stub: chapter tap will seek playback in a future slice
            abs_logger.verbose("Chapter tapped: " .. (self.chapter.title or "untitled")
                .. " at " .. tostring(self.chapter.start) .. "s")
            UIManager:show(InfoMessage:new{
                text = string.format(_("Chapter: %s\nStart: %s"),
                    self.chapter.title or _("Untitled"),
                    widget_helpers.format_time(self.chapter.start)),
                timeout = 2,
            })
            return true
        end
        tap_container[1] = chapter_widget
        table.insert(self.content_group, tap_container)
        table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })
    end

    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.default })
end

------------------------------------------------------------------------
-- Close / navigation
------------------------------------------------------------------------
function BookDetailView:onClose()
    if has_navigator then
        nav.pop()              -- nav.pop() owns UIManager:close(self)
    else
        UIManager:close(self)   -- standalone fallback
    end
    return true
end

function BookDetailView:onSwipe(arg, ges_ev)
    if ges_ev.direction == "south" then
        self:onClose()
    end
    return true
end

------------------------------------------------------------------------
-- Public: show book detail view
-- Uses prepare() for data fetching, then renders the view.
-- When API is configured, fetches async via scheduleIn.
-- When offline, calls prepare() synchronously.
------------------------------------------------------------------------
function detail.show(data)
    data = data or {}
    local item = data.item
    if not item then return nil end
    local on_download = data.on_download

    abs_logger.info("Showing book detail: " .. (item.title or item.id or "unknown"))

    -- Initialize manifest for potential fallback
    if has_manifest then
        manifest.init()
    end

    -- Async path: show loading indicator, call prepare in scheduleIn
    if has_api and api.is_configured() then
        local loading = InfoMessage:new{
            text = _("Loading book details…"),
            timeout = 0,  -- no auto-dismiss
        }
        UIManager:show(loading)

        UIManager:scheduleIn(0.1, function()
            UIManager:close(loading)
            local prepared, err = detail.prepare(item)
            if prepared then
                detail._renderView(prepared, on_download)
            else
                error_handler.show(err.type or "network", err.message or _("Unable to load book details."))
            end
        end)
    else
        -- Synchronous path
        local prepared, err = detail.prepare(item)
        if prepared then
            detail._renderView(prepared, on_download)
        else
            error_handler.show(err.type or "network", err.message or _("Unable to load book details."))
        end
    end
end

------------------------------------------------------------------------
-- Render the detail view widget
------------------------------------------------------------------------
function detail._renderView(item, on_download)
    local view = BookDetailView:new{
        item = item,
        on_download = on_download,
    }
    UIManager:show(view)
    return view
end

------------------------------------------------------------------------
-- Merge expanded API data into the basic item
-- Expanded data from getItemDetails has audioFiles, ebookFiles,
-- and media.chapters at the top level.
------------------------------------------------------------------------
function detail._mergeItemData(base_item, expanded)
    local merged = {}
    for k, v in pairs(base_item) do
        merged[k] = v
    end
    for k, v in pairs(expanded) do
        merged[k] = v
    end
    return merged
end

------------------------------------------------------------------------
-- Build a displayable item from manifest data
-- (for offline viewing of downloaded books)
------------------------------------------------------------------------
function detail._itemFromManifest(item, book)
    return {
        id = item.id or book.abs_item_id,
        title = book.title or item.title,
        author = book.author or "",
        mediaType = item.mediaType or "book",
        addedAt = item.addedAt,
        media = {
            duration = book.duration,
            metadata = {
                title = book.title,
                authorName = book.author,
            },
            chapters = book.chapters or {},
        },
        audioFiles = {},  -- Manifest doesn't track ABS file objects
        ebookFiles = {},  -- Manifest doesn't track ABS file objects
        -- Manifest tracks local files, not ABS audioFiles
    }
end

return detail
