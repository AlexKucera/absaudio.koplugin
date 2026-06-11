-- Widget helpers tests
-- Tests widget_helpers.lua public API: format_duration, format_time,
-- format_file_size, addSeparator, makeTappableButton
--
-- Run with: lua spec/test_widget_helpers.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

-- Stub KOReader dependencies
local Blitbuffer = {
    COLOR_WHITE = { 1 },
    COLOR_BLACK = { 2 },
    COLOR_DARK_GRAY = { 3 },
    COLOR_LIGHT_GRAY = { 4 },
    COLOR_BLUE = { 5 },
    COLOR_GRAY = { 6 },
    COLOR_DARK_GREEN = { 7 },
}
package.loaded["ffi/blitbuffer"] = Blitbuffer
package.loaded["ui/bidi"] = {}
package.loaded["device"] = {
    screen = {
        getSize = function() return { w = 600, h = 800 } end,
        scaleBySize = function(n) return n end,
    },
    hasKeys = function() return false end,
    isTouchDevice = function() return false end,
    input = { group = { Back = "Back" } },
}
package.loaded["ui/font"] = {
    getFace = function() return {} end,
}
package.loaded["ui/size"] = {
    padding = { large = 10, default = 5, small = 2 },
    line = { thin = 1 },
}

-- Widget stubs: return simple constructors that track what was created
local created_widgets = {}
local function make_widget_stub(class_name)
    local function constructor(self, opts)
        local obj = opts or {}
        obj._class = class_name
        obj.getSize = function() return { w = obj.width or obj.w or 100, h = obj.height or obj.h or 20 } end
        table.insert(created_widgets, obj)
        return obj
    end
    return { new = constructor }
end

-- InputContainer needs ges_events initialized
local function make_inputcontainer_stub()
    local function constructor(self, opts)
        local obj = opts or {}
        obj._class = "InputContainer"
        obj.ges_events = obj.ges_events or {}
        obj.getSize = function() return { w = obj.width or obj.w or 100, h = obj.height or obj.h or 20 } end
        table.insert(created_widgets, obj)
        return obj
    end
    return { new = constructor }
end

package.loaded["ui/geometry"] = {
    new = function(self, t) return t end,
}
package.loaded["ui/gesturerange"] = {
    new = function(self, t) return t end,
}
package.loaded["ui/widget/container/inputcontainer"] = make_inputcontainer_stub()
package.loaded["ui/widget/linewidget"] = make_widget_stub("LineWidget")
package.loaded["ui/widget/textwidget"] = make_widget_stub("TextWidget")
package.loaded["ui/widget/verticalspan"] = make_widget_stub("VerticalSpan")
package.loaded["ui/widget/container/centercontainer"] = make_widget_stub("CenterContainer")
package.loaded["gettext"] = function(s) return s end

local helpers = require("absaudio/widget_helpers")

local passed = 0
local failed = 0

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s\nExpected: %q\nActual:   %q",
            msg or "Assertion failed", tostring(expected), tostring(actual)))
    end
end

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("  ✓ " .. name)
    else
        failed = failed + 1
        print("  ✗ " .. name)
        print("    " .. tostring(err))
    end
end

------------------------------------------------------------------------
-- format_duration
------------------------------------------------------------------------
print("format_duration:")
test("returns '0m' for nil", function()
    assert_eq(helpers.format_duration(nil), "0m")
end)

test("returns '0m' for 0", function()
    assert_eq(helpers.format_duration(0), "0m")
end)

test("returns '0m' for negative", function()
    assert_eq(helpers.format_duration(-5), "0m")
end)

test("formats minutes only", function()
    assert_eq(helpers.format_duration(120), "2m")
end)

test("formats hours and minutes", function()
    assert_eq(helpers.format_duration(3661), "1h 1m")
end)

test("formats exact hours", function()
    assert_eq(helpers.format_duration(7200), "2h 0m")
end)

test("formats large duration", function()
    assert_eq(helpers.format_duration(86400), "24h 0m")
end)

------------------------------------------------------------------------
-- format_time
------------------------------------------------------------------------
print("\nformat_time:")
test("returns '0:00' for nil", function()
    assert_eq(helpers.format_time(nil), "0:00")
end)

test("returns '0:00' for 0", function()
    assert_eq(helpers.format_time(0), "0:00")
end)

test("returns '0:00' for negative", function()
    assert_eq(helpers.format_time(-1), "0:00")
end)

test("formats seconds only", function()
    assert_eq(helpers.format_time(45), "0:45")
end)

test("formats minutes and seconds", function()
    assert_eq(helpers.format_time(125), "2:05")
end)

test("formats hours, minutes, seconds", function()
    assert_eq(helpers.format_time(3661), "1:01:01")
end)

------------------------------------------------------------------------
-- format_file_size
------------------------------------------------------------------------
print("\nformat_file_size:")
test("returns '0 B' for nil", function()
    assert_eq(helpers.format_file_size(nil), "0 B")
end)

test("returns '0 B' for 0", function()
    assert_eq(helpers.format_file_size(0), "0 B")
end)

test("returns '0 B' for negative", function()
    assert_eq(helpers.format_file_size(-1), "0 B")
end)

test("formats bytes", function()
    assert_eq(helpers.format_file_size(512), "512 B")
end)

test("formats kilobytes with one decimal", function()
    assert_eq(helpers.format_file_size(1536), "1.5 KB")
end)

test("formats megabytes", function()
    assert_eq(helpers.format_file_size(1048576), "1.0 MB")
end)

test("formats gigabytes", function()
    assert_eq(helpers.format_file_size(1073741824), "1.0 GB")
end)

------------------------------------------------------------------------
-- addSeparator
------------------------------------------------------------------------
print("\naddSeparator:")
test("inserts 2 items into content_group", function()
    created_widgets = {}
    local group = {}
    helpers.addSeparator(group, 500)
    assert_eq(#group, 2, "should insert exactly 2 items")
end)

test("first item is a LineWidget", function()
    created_widgets = {}
    local group = {}
    helpers.addSeparator(group, 500)
    assert_eq(group[1]._class, "LineWidget", "first item should be LineWidget")
end)

test("second item is a VerticalSpan", function()
    created_widgets = {}
    local group = {}
    helpers.addSeparator(group, 500)
    assert_eq(group[2]._class, "VerticalSpan", "second item should be VerticalSpan")
end)

test("line widget uses content_width", function()
    created_widgets = {}
    local group = {}
    helpers.addSeparator(group, 500)
    assert_eq(group[1].dimen.w, 500, "line width should match content_width")
end)

------------------------------------------------------------------------
-- makeTappableButton
------------------------------------------------------------------------
print("\nmakeTappableButton:")
test("returns an InputContainer", function()
    created_widgets = {}
    local btn = helpers.makeTappableButton("Test", function() end)
    assert_eq(btn._class, "InputContainer", "should return InputContainer")
end)

test("child [1] is a TextWidget with correct text", function()
    created_widgets = {}
    local btn = helpers.makeTappableButton("Hello", function() end)
    assert_eq(btn[1]._class, "TextWidget", "child should be TextWidget")
    assert_eq(btn[1].text, "Hello", "text should match")
end)

test("registers a ges_events.Tap handler", function()
    created_widgets = {}
    local btn = helpers.makeTappableButton("Test", function() end)
    assert_eq(btn.ges_events.TapButton ~= nil, true, "should have TapButton event")
end)

test("onTapButton handler calls callback", function()
    created_widgets = {}
    local called = false
    local btn = helpers.makeTappableButton("Test", function() called = true end)
    btn:onTapButton()
    assert_eq(called, true, "callback should have been called")
end)

test("custom tap_event_name works", function()
    created_widgets = {}
    local btn = helpers.makeTappableButton("Test", function() end, {
        tap_event_name = "TapCustom",
    })
    assert_eq(btn.ges_events.TapCustom ~= nil, true, "should have custom event")
    assert_eq(btn.onTapCustom ~= nil, true, "should have custom handler")
end)

test("ref_obj and ref_key are attached", function()
    created_widgets = {}
    local ref = { name = "myref" }
    local btn = helpers.makeTappableButton("Test", function() end, {
        ref_obj = ref,
        ref_key = "my_ref",
    })
    assert_eq(btn.my_ref, ref, "ref should be attached")
end)

test("custom width is used for dimen", function()
    created_widgets = {}
    local btn = helpers.makeTappableButton("Test", function() end, {
        width = 300,
        height = 50,
    })
    assert_eq(btn.dimen.w, 300, "width should be 300")
    assert_eq(btn.dimen.h, 50, "height should be 50")
end)

------------------------------------------------------------------------
-- format_bytes
------------------------------------------------------------------------
print("\nformat_bytes:")
test("returns '0 B' for nil", function()
    assert_eq(helpers.format_bytes(nil), "0 B")
end)

test("returns '0 B' for 0", function()
    assert_eq(helpers.format_bytes(0), "0 B")
end)

test("returns '0 B' for negative", function()
    assert_eq(helpers.format_bytes(-1), "0 B")
end)

test("formats bytes", function()
    assert_eq(helpers.format_bytes(512), "512 B")
end)

test("formats kilobytes with one decimal", function()
    assert_eq(helpers.format_bytes(1536), "1.5 KB")
end)

test("formats megabytes", function()
    assert_eq(helpers.format_bytes(1048576), "1.0 MB")
end)

test("formats gigabytes", function()
    assert_eq(helpers.format_bytes(1073741824), "1.0 GB")
end)

------------------------------------------------------------------------
-- Summary
------------------------------------------------------------------------
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
