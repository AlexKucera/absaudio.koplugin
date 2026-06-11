-- Shared widget helpers for absaudio.koplugin
-- Consolidates triplicated code from dashboard_widget, library_browser, book_detail
-- into a single utility module.
--
-- Public API:
--   format_duration(seconds)  — "Xh Ym" or "Ym" or "0m"
--   format_time(seconds)      — "H:MM:SS" or "M:SS" or "0:00"
--   format_file_size(bytes)   — "50 MB", "1.2 GB", etc.
--   addSeparator(content_group, content_width)  — insert line + spacer
--   makeTappableButton(text, on_tap, opts)      — create InputContainer+TextWidget+Tap
-- Return convention: direct value (string or widget) — pure utility functions, no error wrapping.

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalSpan = require("ui/widget/verticalspan")

local helpers = {}

------------------------------------------------------------------------
-- Format seconds as "Xh Ym" or "Ym" or "0m"
------------------------------------------------------------------------
function helpers.format_duration(seconds)
    if not seconds or seconds <= 0 then return "0m" end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    if h > 0 then
        return string.format("%dh %dm", h, m)
    end
    return string.format("%dm", m)
end

------------------------------------------------------------------------
-- Format seconds as "HH:MM:SS" or "MM:SS"
------------------------------------------------------------------------
function helpers.format_time(seconds)
    if not seconds or seconds < 0 then return "0:00" end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = math.floor(seconds % 60)
    if h > 0 then
        return string.format("%d:%02d:%02d", h, m, s)
    end
    return string.format("%d:%02d", m, s)
end

------------------------------------------------------------------------
-- Format bytes as "50 MB", "1.2 GB", etc.
------------------------------------------------------------------------
function helpers.format_file_size(bytes)
    if not bytes or bytes <= 0 then return "0 B" end
    local units = { "B", "KB", "MB", "GB", "TB" }
    local size = bytes
    local unit_idx = 1
    while size >= 1024 and unit_idx < #units do
        size = size / 1024
        unit_idx = unit_idx + 1
    end
    if unit_idx > 1 then
        return string.format("%.1f %s", size, units[unit_idx])
    end
    return string.format("%d %s", size, units[unit_idx])
end

------------------------------------------------------------------------
-- Format bytes as human-readable string: "1.5 GB", "200 MB", etc.
-- @param b number  bytes
-- @return string
------------------------------------------------------------------------
function helpers.format_bytes(b)
    if not b or b <= 0 then return "0 B" end
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

------------------------------------------------------------------------
-- Insert a horizontal separator line + small spacer into a content group
-- @param content_group  VerticalGroup to insert into
-- @param content_width  pixel width for the line
------------------------------------------------------------------------
function helpers.addSeparator(content_group, content_width)
    table.insert(content_group, LineWidget:new{
        background = Blitbuffer.COLOR_DARK_GRAY,
        dimen = Geom:new{
            w = content_width,
            h = Size.line.thin,
        },
    })
    table.insert(content_group, VerticalSpan:new{ width = Size.padding.small })
end

------------------------------------------------------------------------
-- Create a tappable button (InputContainer + TextWidget + ges_events.Tap)
-- @param text      string       button label
-- @param on_tap    function()   callback when tapped
-- @param opts      table|nil    optional: width, height, face, fgcolor, tap_event_name, ref_obj, ref_key
-- @return InputContainer with [1] = TextWidget
------------------------------------------------------------------------
function helpers.makeTappableButton(text, on_tap, opts)
    opts = opts or {}
    local face = opts.face or require("ui/font"):getFace("cfont", 16)
    local fgcolor = opts.fgcolor or Blitbuffer.COLOR_BLUE

    local btn = TextWidget:new{
        text = text,
        face = face,
        fgcolor = fgcolor,
    }

    local tap_event_name = opts.tap_event_name or "TapButton"

    local container = InputContainer:new{
        dimen = Geom:new{
            w = opts.width or 200,
            h = opts.height or (btn:getSize().h + Size.padding.default),
        },
    }
    container.ges_events[tap_event_name] = GestureRange:new{
        ges = "tap",
        range = container.dimen,
    }

    -- Attach ref object if provided (for callback context)
    if opts.ref_obj and opts.ref_key then
        container[opts.ref_key] = opts.ref_obj
    end

    -- Define tap handler as a method on the container
    local handler_name = "on" .. tap_event_name
    container[handler_name] = function(self)
        on_tap()
        return true
    end

    container[1] = btn
    return container
end

return helpers
