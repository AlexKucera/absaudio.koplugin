-- Navigator module for absaudio.koplugin
-- Manages a screen stack for widget navigation, replacing callback chains.
--
-- Public API:
--   nav.register(name, show_fn)  — register a screen by name with its show function
--   nav.push(name, data)         — push a screen: close current widget, show target
--   nav.pop()                    — pop the stack: close current widget, re-show previous
--   nav.reset(name, data)        — clear the stack and show a screen (for initial load)
--   nav._reset()                 — clear all state (for testing)
-- Return convention: void for push/pop/reset; boolean for async show_fn (true=async).

local nav = {}

-- Internal state
local _screens = {}       -- map of name → show_fn
local _stack = {}         -- array of {name, data} entries
local _current = nil      -- reference to the currently-shown widget
local _current_name = nil -- name of the current screen
local _current_data = nil -- data passed to the current screen's show_fn
local _deferred_close = nil -- widget to close when async screen's _setCurrent fires

--- Clear all navigator state (for testing)
function nav._reset()
    _screens = {}
    _stack = {}
    _current = nil
    _current_name = nil
    _current_data = nil
    _deferred_close = nil
end

--- Register a screen by name with its show function
--- @param name string   screen name
--- @param show_fn function  function(data) → widget_instance
function nav.register(name, show_fn)
    _screens[name] = show_fn
end

--- Push a screen onto the stack: close current, show target
--- @param name string  registered screen name
--- @param data table   data to pass to show_fn
function nav.push(name, data)
    local abs_logger = require("abs_logger")

    local show_fn = _screens[name]
    if not show_fn then
        abs_logger.warn("navigator: attempted to push unregistered screen '" .. tostring(name) .. "'")
        return
    end

    -- Save previous state for rollback if show_fn fails
    local prev_widget = _current
    local prev_name = _current_name
    local prev_data = _current_data

    -- Push current screen onto stack (so pop can return to it)
    if _current_name then
        table.insert(_stack, { name = _current_name, data = _current_data })
    end

    -- Defer closing the previous widget:
    --   - Sync screens: close after show_fn returns (new widget already shown)
    --   - Async screens: close in _setCurrent when the real widget is ready
    -- This avoids a flash of the underlying KOReader view between transitions.
    local deferred_close = _current
    _current = nil  -- clear before show_fn; async screens set it later via _setCurrent

    -- Show the new screen
    -- show_fn may return:
    --   a widget  — ready immediately
    --   true      — async in progress, will call _setCurrent() later
    --   nil       — failure, trigger rollback
    local result = show_fn(data)

    if result == nil then
        -- show_fn failed — rollback to previous screen
        abs_logger.warn("navigator: show_fn for '" .. tostring(name) .. "' returned nil, rolling back")
        table.remove(_stack)
        -- Keep deferred_close visible — it's the screen we're rolling back to
        _current = deferred_close
        _current_name = prev_name
        _current_data = prev_data
        return
    end

    -- For async screens (result == true), _current stays nil until
    -- _setCurrent is called. _current_name/data are set so the stack
    -- and pop() work correctly.
    if result ~= true then
        -- Sync screen: new widget already shown by show_fn, now close old
        if deferred_close then
            local UIManager = require("ui/uimanager")
            UIManager:close(deferred_close)
        end
        _current = result
    else
        -- Async screen: keep old widget visible until _setCurrent fires
        _deferred_close = deferred_close
    end
    _current_name = name
    _current_data = data
end

--- Pop the stack: close current, re-show previous screen
function nav.pop()
    if #_stack == 0 then
        return  -- empty stack, no-op
    end

    -- Close current widget (may be nil for failed async screens)
    if _current then
        local UIManager = require("ui/uimanager")
        UIManager:close(_current)
    end

    -- If an async screen was in progress with a deferred-close widget
    -- visible, that widget IS the previous screen we're popping back to
    -- (e.g., library browser visible behind a failed detail loading).
    -- Don't close it — just cancel the deferred state.
    if _deferred_close then
        _deferred_close = nil
    end

    -- Pop the previous entry
    local entry = table.remove(_stack)

    -- Re-show the previous screen
    local show_fn = _screens[entry.name]
    if show_fn then
        _current = show_fn(entry.data)
        _current_name = entry.name
        _current_data = entry.data
    else
        _current = nil
        _current_name = nil
        _current_data = nil
    end
end

--- Clear the stack and show a screen (for initial load)
--- @param name string  registered screen name
--- @param data table   data to pass to show_fn
function nav.reset(name, data)
    local show_fn = _screens[name]
    if not show_fn then
        local abs_logger = require("abs_logger")
        abs_logger.warn("navigator: attempted to reset to unregistered screen '" .. tostring(name) .. "'")
        return
    end

    -- Close current widget
    if _current then
        local UIManager = require("ui/uimanager")
        UIManager:close(_current)
    end

    -- Clear the stack and any pending deferred close
    _stack = {}
    _deferred_close = nil

    -- Show the screen
    _current = show_fn(data)
    _current_name = name
    _current_data = data
end

--- Replace the current widget reference without changing the stack.
--- Use when a screen recreates its own widget (e.g., page navigation refresh).
--- @param widget table  the new widget instance
function nav._setCurrent(widget)
    if _deferred_close then
        local UIManager = require("ui/uimanager")
        UIManager:close(_deferred_close)
        _deferred_close = nil
    end
    _current = widget
end

--- Get the current screen name (for testing)
function nav._current_name()
    return _current_name
end

--- Get the current widget reference (for testing)
function nav._current_widget()
    return _current
end

return nav
