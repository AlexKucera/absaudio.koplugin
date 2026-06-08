-- Dashboard widget for absaudio.koplugin
-- Root view with 4 sections: Resume Last Book, Downloaded Books, Browse Library, Settings
-- Reads real data from manifest and API modules.
--
-- Public API:
--   dashboard.show()  — display the dashboard

local Blitbuffer = require("ffi/blitbuffer")
local BD = require("ui/bidi")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
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

-- Try to load manifest and api
local has_manifest, manifest = pcall(require, "manifest")
local has_api, api = pcall(require, "api")

local dashboard = {}

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

    -- Build the dashboard content
    self.content_group = VerticalGroup:new{ align = "left" }

    -- Add top padding so content isn't flush against the very top
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.large })

    -- Title
    self:_addTitle()

    -- Resume Last Book section
    self:_addResumeSection()

    -- Separator
    self:_addSeparator()

    -- Downloaded Books section
    self:_addDownloadedBooksSection()

    -- Separator
    self:_addSeparator()

    -- Browse Library button
    self:_addBrowseLibraryButton()

    -- Separator
    self:_addSeparator()

    -- Settings entry
    self:_addSettingsButton()

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

    -- Get most recently played book from manifest
    local recent_book = nil
    if has_manifest then
        recent_book = manifest.getRecentBook()
    end

    if recent_book and recent_book.current_time and recent_book.current_time > 0 then
        -- Show book info with resume button
        local progress_text = format_progress(recent_book.current_time, recent_book.duration)
            .. " · " .. format_duration(recent_book.current_time)
            .. " / " .. format_duration(recent_book.duration)

        local info_text = string.format("%s\n%s\n%s\n▶ Resume",
            recent_book.title or "Unknown",
            recent_book.author or "",
            progress_text)

        local info_widget = TextBoxWidget:new{
            text = info_text,
            face = Font:getFace("cfont", 15),
            width = self.content_width,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }

        -- Wrap in a tappable container
        local tap_container = InputContainer:new{
            dimen = Geom:new{
                w = self.content_width,
                h = info_widget:getSize().h,
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
        tap_container[1] = info_widget
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

    -- Get all books from manifest
    local books = {}
    if has_manifest then
        books = manifest.getAllBooks()
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
                    .. " · " .. format_duration(book.current_time or 0)
                    .. " / " .. format_duration(book.duration)
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

            local book_widget = TextBoxWidget:new{
                text = title_text,
                face = Font:getFace("cfont", 14),
                width = self.content_width,
            }
            table.insert(self.content_group, book_widget)
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
    local btn = TextWidget:new{
        text = _("Browse Library"),
        face = Font:getFace("cfont", 16),
        fgcolor = Blitbuffer.COLOR_BLUE,
    }

    local tap_container = InputContainer:new{
        dimen = Geom:new{
            w = self.content_width,
            h = btn:getSize().h + Size.padding.default,
        },
    }
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
    tap_container[1] = btn
    table.insert(self.content_group, tap_container)
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.default })
end

function DashboardView:_addSettingsButton()
    local btn = TextWidget:new{
        text = _("Settings"),
        face = Font:getFace("cfont", 16),
        fgcolor = Blitbuffer.COLOR_BLUE,
    }

    local tap_container = InputContainer:new{
        dimen = Geom:new{
            w = self.content_width,
            h = btn:getSize().h + Size.padding.default,
        },
    }
    tap_container.ges_events.TapSettings = {
        GestureRange:new{
            ges = "tap",
            range = tap_container.dimen,
        },
    }
    tap_container.dashboard_ref = self.dashboard_ref
    function tap_container:onTapSettings()
        self.dashboard_ref:_onOpenSettings()
        return true
    end
    tap_container[1] = btn
    table.insert(self.content_group, tap_container)
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.default })
end

function DashboardView:_addSeparator()
    table.insert(self.content_group, LineWidget:new{
        background = Blitbuffer.COLOR_DARK_GRAY,
        dimen = Geom:new{
            w = self.content_width,
            h = Size.line.thin,
        },
    })
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })
end

-- Actions

function DashboardView:_onResumeBook(book)
    abs_logger.info("Resume book: " .. (book.title or "unknown"))
    -- Stub — full playback integration in later slice
    UIManager:show(InfoMessage:new{
        text = string.format(_("Resume: %s\nPosition: %s / %s"),
            book.title or "Unknown",
            format_duration(book.current_time),
            format_duration(book.duration)),
        timeout = 3,
    })
end

function DashboardView:_onBrowseLibrary()
    abs_logger.info("Browse Library tapped")
    -- Stub — library browser in slice 3
    if not has_api or not api.is_configured() then
        error_handler.show("auth", "Configure your server settings first.")
        return
    end
    UIManager:show(InfoMessage:new{
        text = _("Library browser coming soon.\nThis will show your ABS library with search, sort, and pagination."),
        timeout = 3,
    })
end

function DashboardView:_onOpenSettings()
    abs_logger.info("Settings tapped from dashboard")
    -- Open settings — find the plugin instance and call its onShowSettings
    -- Walk UIManager's widget stack to find the ABSAudio plugin
    -- For now, show a hint message (full wiring needs plugin reference)
    UIManager:show(InfoMessage:new{
        text = _("Open Settings from:\nMenu → Plugins → ABS Audio → Settings\n\nSync Now and Export Diagnostics coming in a future update."),
        timeout = 5,
    })
end

function DashboardView:onClose()
    UIManager:close(self)
    return true
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
function dashboard.show()
    abs_logger.info("Showing dashboard")

    -- Initialize manifest if available
    if has_manifest then
        manifest.init()
    end

    local view = DashboardView:new{}
    UIManager:show(view)
end

return dashboard
