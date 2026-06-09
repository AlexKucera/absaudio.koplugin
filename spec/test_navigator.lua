-- Navigator module tests
-- Tests navigator.lua public API: register, push, pop, reset
--
-- Run with: lua spec/test_navigator.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

------------------------------------------------------------------------
-- Stub all KOReader dependencies
------------------------------------------------------------------------

package.loaded["abs_logger"] = {
    verbose = function() end,
    info = function() end,
    warn = function() end,
    set_level = function() end,
}

local close_log = {}
package.loaded["ui/uimanager"] = {
    show = function() end,
    close = function(self, widget)
        table.insert(close_log, widget)
    end,
    scheduleIn = function() end,
}

------------------------------------------------------------------------
-- Require module under test
------------------------------------------------------------------------
local nav = require("absaudio/navigator")
local mock = require("spec/test_helper")

------------------------------------------------------------------------
-- Test runner
------------------------------------------------------------------------
local passed = 0
local failed = 0
local errors = {}

local function run_test(name, fn)
    -- Reset navigator state before each test
    nav._reset()
    close_log = {}

    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("  ✓ " .. name)
    else
        failed = failed + 1
        table.insert(errors, { name = name, err = err })
        print("  ✗ " .. name)
        print("    " .. tostring(err))
    end
end

-- ============================================================
-- Test 1: register + push — verify show_fn called with correct data
-- ============================================================
run_test("register + push calls show_fn with correct data", function()
    local received_data = nil
    local function home_show(data)
        received_data = data
        return { name = "home_widget" }
    end

    nav.register("home", home_show)
    nav.push("home", { title = "Hello" })

    mock.assert_equals(received_data ~= nil, true, "show_fn should have been called")
    mock.assert_equals(received_data.title, "Hello", "show_fn should receive correct data")
end)

-- ============================================================
-- Test 2: push then pop — verify previous screen re-shown
-- ============================================================
run_test("push then pop re-shows previous screen", function()
    local home_data = nil
    local function home_show(data)
        home_data = data
        return { name = "home_widget" }
    end

    local browser_data = nil
    local function browser_show(data)
        browser_data = data
        return { name = "browser_widget" }
    end

    nav.register("home", home_show)
    nav.register("browser", browser_show)

    -- Push home first
    nav.push("home", { title = "Home" })
    mock.assert_equals(home_data.title, "Home", "home show_fn should receive data")

    -- Push browser on top
    nav.push("browser", { query = "test" })
    mock.assert_equals(browser_data.query, "test", "browser show_fn should receive data")

    -- Reset home_data to verify pop calls it again
    home_data = nil

    -- Pop should re-show home
    nav.pop()
    mock.assert_equals(home_data ~= nil, true, "home show_fn should be called again after pop")
    mock.assert_equals(home_data.title, "Home", "home show_fn should receive original data")
end)

-- ============================================================
-- Test 3: pop on empty stack is a no-op
-- ============================================================
run_test("pop on empty stack is a no-op", function()
    -- Should not error
    nav.pop()
    mock.assert_equals(true, true, "pop on empty stack should not crash")
end)

-- ============================================================
-- Test 4: push then push then pop — three screens deep
-- ============================================================
run_test("push three screens deep, pop returns to middle", function()
    local show_log = {}

    local function screen_show(name)
        return function(data)
            table.insert(show_log, { name = name, data = data })
            return { widget_name = name }
        end
    end

    nav.register("dashboard", screen_show("dashboard"))
    nav.register("browser", screen_show("browser"))
    nav.register("detail", screen_show("detail"))

    nav.push("dashboard", { screen = 1 })
    nav.push("browser", { screen = 2 })
    nav.push("detail", { screen = 3 })

    mock.assert_equals(#show_log, 3, "three screens should have been shown")
    mock.assert_equals(show_log[3].data.screen, 3, "last shown should be detail")

    -- Pop should return to browser
    nav.pop()
    mock.assert_equals(#show_log, 4, "pop should trigger another show")
    mock.assert_equals(show_log[4].data.screen, 2, "should re-show browser (screen 2)")
end)

-- ============================================================
-- Test 5: reset clears stack and shows screen
-- ============================================================
run_test("reset clears stack and shows screen, pop is no-op", function()
    local show_log = {}

    local function screen_show(name)
        return function(data)
            table.insert(show_log, { name = name })
            return { widget_name = name }
        end
    end

    nav.register("dashboard", screen_show("dashboard"))
    nav.register("browser", screen_show("browser"))
    nav.register("settings", screen_show("settings"))

    -- Push two screens
    nav.push("dashboard", {})
    nav.push("browser", {})

    -- Reset to settings (clears stack)
    nav.reset("settings", {})

    mock.assert_equals(show_log[#show_log].name, "settings", "last shown should be settings")

    -- Pop should be no-op (stack was cleared)
    nav.pop()
    mock.assert_equals(#show_log, 3, "no additional show after pop on cleared stack")
end)

-- ============================================================
-- Test 6: re-registration overwrites previous
-- ============================================================
run_test("re-registration overwrites previous show_fn", function()
    local fn_a_called = false
    local fn_b_called = false

    local function fn_a(data)
        fn_a_called = true
        return { name = "a" }
    end
    local function fn_b(data)
        fn_b_called = true
        return { name = "b" }
    end

    nav.register("home", fn_a)
    nav.register("home", fn_b)  -- overwrite

    nav.push("home", {})

    mock.assert_equals(fn_a_called, false, "fn_a should NOT be called after re-registration")
    mock.assert_equals(fn_b_called, true, "fn_b should be called after re-registration")
end)

-- ============================================================
-- Test 7: push with unregistered name logs warning, no crash
-- ============================================================
run_test("push with unregistered name does not crash", function()
    -- Should not error
    nav.push("nonexistent", {})
    mock.assert_equals(true, true, "pushing unregistered screen should not crash")
end)

-- ============================================================
-- Test 8: UIManager:close called on current widget during push
-- ============================================================
run_test("UIManager:close called on current widget during push", function()
    local widget_a = { name = "widget_a" }
    local widget_b = { name = "widget_b" }

    nav.register("a", function() return widget_a end)
    nav.register("b", function() return widget_b end)

    nav.push("a", {})
    mock.assert_equals(#close_log, 0, "no close on first push")

    nav.push("b", {})
    mock.assert_equals(#close_log, 1, "one close on second push")
    mock.assert_equals(close_log[1], widget_a, "widget_a should have been closed")
end)

-- ============================================================
-- Test 9: UIManager:close called on current widget during pop
-- ============================================================
run_test("UIManager:close called on current widget during pop", function()
    local widget_a = { name = "widget_a" }
    local widget_b = { name = "widget_b" }

    nav.register("a", function() return widget_a end)
    nav.register("b", function() return widget_b end)

    nav.push("a", {})
    nav.push("b", {})

    -- Reset close log (from the push)
    close_log = {}

    nav.pop()
    mock.assert_equals(#close_log, 1, "one close on pop")
    mock.assert_equals(close_log[1], widget_b, "widget_b should have been closed on pop")
end)

-- ============================================================
-- Test 10: push rollback when show_fn returns nil (reentrant corruption fix)
-- ============================================================
run_test("push rolls back when show_fn returns nil", function()
    local widget_a = { name = "widget_a" }
    local widget_b = { name = "widget_b" }
    local show_b_calls = 0

    nav.register("a", function() return widget_a end)
    nav.register("b", function()
        show_b_calls = show_b_calls + 1
        return nil  -- simulate failure
    end)

    nav.push("a", {})
    mock.assert_equals(nav._current_name(), "a", "screen A should be active")

    -- Reset close log
    close_log = {}

    -- Push B which fails — should roll back to A
    nav.push("b", {})
    mock.assert_equals(nav._current_name(), "a", "should roll back to A after B fails")
    mock.assert_equals(nav._current_widget(), widget_a, "should show widget_a after rollback")
    mock.assert_equals(show_b_calls, 1, "B's show_fn should be called exactly once")
end)

-- ============================================================
-- Test 11: push rollback does not corrupt stack
-- ============================================================
run_test("push rollback keeps stack consistent for subsequent pops", function()
    local widget_home = { name = "home" }
    local widget_a = { name = "a" }
    local widget_b = { name = "b" }
    local show_b_calls = 0

    nav.register("home", function() return widget_home end)
    nav.register("a", function() return widget_a end)
    nav.register("b", function()
        show_b_calls = show_b_calls + 1
        return nil  -- simulate failure
    end)

    nav.push("home", {})
    nav.push("a", {})
    mock.assert_equals(nav._current_name(), "a", "screen A should be active")

    close_log = {}

    -- B fails, should roll back to A
    nav.push("b", {})
    mock.assert_equals(nav._current_name(), "a", "should roll back to A")

    -- Now pop should work correctly back to home
    close_log = {}
    nav.pop()
    mock.assert_equals(nav._current_name(), "home", "pop after failed push should return to home")
    mock.assert_equals(nav._current_widget(), widget_home, "should show home widget")
end)

-- ============================================================
-- Summary
-- ============================================================
print(string.format("\n%d passed, %d failed", passed, failed))

if #errors > 0 then
    print("\nFailures:")
    for _, e in ipairs(errors) do
        print("  " .. e.name .. ": " .. tostring(e.err))
    end
    os.exit(1)
end
