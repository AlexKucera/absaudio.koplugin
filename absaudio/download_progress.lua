-- Download progress widget for absaudio.koplugin
-- Fullscreen overlay showing download progress with cancel button.
--
-- Public API:
--   progress.show(data)
--     data: { state=download_state, on_cancel=function() end }
--   progress.close()
--   progress.format_progress_info(state)

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local Screen = Device.screen

local abs_logger = require("abs_logger")

local progress = {}
local _widget = nil  -- reference to current widget

------------------------------------------------------------------------
-- Format download progress info from state
-- @param state table  download state from create_download_state()
-- @return string  formatted progress text
------------------------------------------------------------------------
function progress.format_progress_info(state)
    local current = state.current_file or 0
    local total = state.total_files or 0
    local downloaded = state.bytes_downloaded or 0
    local total_bytes = state.total_bytes or 0
    local fraction = state:progress_fraction()
    local pct = math.floor(fraction * 100)

    local function format_bytes(b)
        if b >= 1073741824 then
            return string.format("%.1f GB", b / 1073741824)
        elseif b >= 1048576 then
            return string.format("%.1f MB", b / 1048576)
        elseif b >= 1024 then
            return string.format("%.1f KB", b / 1024)
        else
            return tostring(b) .. " B"
        end
    end

    local lines = {}
    table.insert(lines, string.format(_("Downloading file %d of %d"), current, total))
    table.insert(lines, string.format(_("%s / %s (%d%%)"),
        format_bytes(downloaded), format_bytes(total_bytes), pct))

    -- ETA estimate
    if state.start_time and downloaded > 0 and fraction < 1 then
        local elapsed = os.time() - state.start_time
        if elapsed > 0 then
            local rate = downloaded / elapsed
            if rate > 0 then
                local remaining = (total_bytes - downloaded) / rate
                local mins = math.floor(remaining / 60)
                local secs = math.floor(remaining % 60)
                table.insert(lines, string.format(_("ETA: %dm %ds"), mins, secs))
            end
        end
    end

    return table.concat(lines, "\n")
end

------------------------------------------------------------------------
-- Download Progress Widget
------------------------------------------------------------------------
local DownloadProgressView = FocusManager:extend{
    name = "absaudio_download_progress",
    covers_fullscreen = true,
}

function DownloadProgressView:init()
    if Device:hasKeys() then
        self.key_events = self.key_events or {}
        self.key_events.Close = { { Device.input.group.Back } }
    end

    local screen_size = Screen:getSize()
    self.dimen = screen_size
    self.screen_width = screen_size.w
    self.screen_height = screen_size.h
    self.content_width = self.screen_width - 4 * Size.padding.large

    -- Build content
    self.content_group = VerticalGroup:new{ align = "center" }

    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.large })

    -- Title
    local title = TextWidget:new{
        text = _("Downloading…"),
        face = Font:getFace("tfont", 22),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    table.insert(self.content_group, title)
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.default })

    -- Progress text (updated dynamically)
    local info_text = progress.format_progress_info(self.state or {})
    self.progress_text = TextWidget:new{
        text = info_text,
        face = Font:getFace("cfont", 16),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    table.insert(self.content_group, self.progress_text)
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.large })

    -- Cancel button
    local cancel_text = TextWidget:new{
        text = _("Cancel"),
        face = Font:getFace("cfont", 18),
        fgcolor = Blitbuffer.COLOR_BLUE,
    }
    local cancel_container = InputContainer:new{
        dimen = Geom:new{
            w = self.screen_width,
            h = cancel_text:getSize().h + 2 * Size.padding.default,
        },
    }
    cancel_container.ges_events.TapCancel = {
        GestureRange:new{
            ges = "tap",
            range = cancel_container.dimen,
        },
    }
    cancel_container._on_cancel = self.on_cancel
    cancel_container._widget_ref = self
    function cancel_container:onTapCancel()
        if self._on_cancel then self._on_cancel() end
        return true
    end
    cancel_container[1] = cancel_text
    table.insert(self.content_group, cancel_container)

    -- Main frame
    self[1] = FrameContainer:new{
        width = self.screen_width,
        height = self.screen_height,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = Size.padding.large,
        margin = 0,
        self.content_group,
    }
end

------------------------------------------------------------------------
-- Update the progress display with new state
------------------------------------------------------------------------
function DownloadProgressView:update(state)
    self.state = state
    if self.progress_text then
        self.progress_text:setText(progress.format_progress_info(state))
        UIManager:setDirty(self, "fast")
    end
end

function DownloadProgressView:onClose()
    UIManager:close(self)
    return true
end

------------------------------------------------------------------------
-- Public: show download progress widget
-- @param data table  { state=download_state, on_cancel=function() }
------------------------------------------------------------------------
function progress.show(data)
    data = data or {}
    abs_logger.info("Showing download progress widget")

    _widget = DownloadProgressView:new{
        state = data.state,
        on_cancel = data.on_cancel,
    }
    UIManager:show(_widget)
    UIManager:setDirty(_widget, "full")
    return _widget
end

------------------------------------------------------------------------
-- Public: close the download progress widget
------------------------------------------------------------------------
function progress.close()
    if _widget then
        UIManager:close(_widget)
        _widget = nil
    end
end

------------------------------------------------------------------------
-- Public: update progress display
-- @param state table  current download state
------------------------------------------------------------------------
function progress.update(state)
    if _widget then
        _widget:update(state)
    end
end

return progress
