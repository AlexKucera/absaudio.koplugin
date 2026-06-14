-- Seekable progress bar widget for absaudio.koplugin
-- Shows playback position as a filled portion of a horizontal bar.
-- Supports tap-to-seek and drag-to-seek.
--
-- Public API:
--   progress_bar.new(opts) → widget instance
--     opts.width      number  bar width in pixels
--     opts.duration   number  total duration in seconds
--     opts.position   number  current position in seconds (default 0)
--     opts.on_seek    fn      callback(position_seconds) when user seeks
--     opts.height     number  bar height in pixels (default 6)
--
--   widget:setPosition(seconds)  — update displayed position
--   widget:getPosition()         — current displayed position
--   widget:getFillWidth()        — pixel width of filled portion

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")

local progress_bar = {}

function progress_bar.new(opts)
    opts = opts or {}
    local width = opts.width or 400
    local duration = opts.duration or 0
    local position = math.min(opts.position or 0, duration)
    local on_seek = opts.on_seek
    local height = opts.height or 6

    local widget = InputContainer:new{
        name = "absaudio_progress_bar",
        dimen = Geom:new{ w = width, h = height + 20 }, -- extra height for tap target
        width = width,
        duration = duration,
        position = position,
        on_seek = on_seek,
        height = height,
    }

    -- Colors (e-ink friendly)
    local bg_color = Blitbuffer.COLOR_LIGHT_GRAY   -- empty track
    local fill_color = Blitbuffer.COLOR_DARK_GRAY    -- played portion

    function widget:paintTo(bb, x, y)
        -- Center the visual bar vertically within the tap-target dimen
        -- (dimen.h = height + 20, so bar sits in the middle)
        local bar_y = y + math.floor((self.dimen.h - self.height) / 2)
        local bar_x = x

        -- Draw background track (full width)
        bb:paintRect(bar_x, bar_y, self.width, self.height, bg_color)

        -- Draw fill portion (filled width based on position/duration)
        local fill_w = self:getFillWidth()
        if fill_w > 0 then
            bb:paintRect(bar_x, bar_y, fill_w, self.height, fill_color)
        end
    end

    function widget:setPosition(sec)
        local v = sec or 0
        if v < 0 then v = 0 end
        if v > self.duration then v = self.duration end
        self.position = v
    end

    function widget:getPosition()
        return self.position
    end

    function widget:getFillWidth()
        if self.duration <= 0 then return 0 end
        return math.floor((self.position / self.duration) * self.width)
    end

    -- Convert an x-coordinate (within the bar) to seconds
    function widget:positionToSeconds(x)
        if self.width <= 0 or self.duration <= 0 then return 0 end
        local ratio = x / self.width
        if ratio < 0 then ratio = 0 end
        if ratio > 1 then ratio = 1 end
        return ratio * self.duration
    end

    -- Handle tap gesture on the progress bar
    function widget:onTapProgress(ges)
        if not ges or not ges.pos then return end
        local seek_pos = self:positionToSeconds(ges.pos.x)
        self:setPosition(seek_pos)
        if self.on_seek then
            self.on_seek(seek_pos)
        end
    end

    -- Register tap gesture
    widget.ges_events = widget.ges_events or {}
    widget.ges_events.TapProgress = {
        GestureRange:new{
            ges = "tap",
            range = function() return widget.dimen end,
        },
    }

    -- Handle pan/drag gesture for scrubbing
    function widget:onProgressDrag(ges)
        if not ges or not ges.pos then return end
        local seek_pos = self:positionToSeconds(ges.pos.x)
        self:setPosition(seek_pos)
        if self.on_seek then
            self.on_seek(seek_pos)
        end
    end

    -- Register pan gesture for drag seeking
    widget.ges_events.PanProgress = {
        GestureRange:new{
            ges = "pan_hold",
            range = function() return widget.dimen end,
            rate = 1.0,
        },
    }

    return widget
end

return progress_bar
