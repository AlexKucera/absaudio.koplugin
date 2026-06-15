-- Wake-lock tests (issue #34, audio slice C)
--
-- The wake_lock is a paired, idempotent wrapper around the PocketBook firmware
-- sleep-ban. The real inkview symbol is behind an injectable impl so the control
-- flow is fully unit-testable on the dev Mac with a counting fake.
--
-- Run with: luajit spec/test_wake_lock.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local mock = require("spec/test_helper")
local wake_lock = require("absaudio/wake_lock")

local passed = 0
local failed = 0
local errors = {}

local function run_test(name, fn)
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

-- Build a counting fake impl + lock.
local function new_counting_lock()
    local calls = { acquire = 0, release = 0 }
    local lock = wake_lock.new({
        impl = {
            acquire = function() calls.acquire = calls.acquire + 1 end,
            release = function() calls.release = calls.release + 1 end,
        },
    })
    return lock, calls
end

-- ============================================================
-- Slice 1: new lock is not held
-- ============================================================

run_test("new lock: is_held() == false", function()
    local lock = new_counting_lock()
    mock.assert_equals(lock:is_held(), false, "fresh lock is not held")
end)

-- ============================================================
-- Slice 2: acquire() sets held + calls impl.acquire once
-- ============================================================

run_test("acquire(): is_held() == true; impl.acquire called once", function()
    local lock, calls = new_counting_lock()
    lock:acquire()
    mock.assert_equals(lock:is_held(), true, "held after acquire")
    mock.assert_equals(calls.acquire, 1, "impl.acquire called exactly once")
end)

-- ============================================================
-- Slice 3: double acquire is idempotent
-- ============================================================

run_test("double acquire is idempotent: impl.acquire called once", function()
    local lock, calls = new_counting_lock()
    lock:acquire()
    lock:acquire()
    mock.assert_equals(calls.acquire, 1, "second acquire did not re-call impl")
    mock.assert_equals(lock:is_held(), true, "still held")
end)

-- ============================================================
-- Slice 4: release() clears held + calls impl.release once
-- ============================================================

run_test("release(): is_held() == false; impl.release called once", function()
    local lock, calls = new_counting_lock()
    lock:acquire()
    lock:release()
    mock.assert_equals(lock:is_held(), false, "not held after release")
    mock.assert_equals(calls.release, 1, "impl.release called exactly once")
end)

-- ============================================================
-- Slice 5: release when not held is a no-op (no error)
-- ============================================================

run_test("release when not held is a no-op: impl.release not called", function()
    local lock, calls = new_counting_lock()
    lock:release()  -- never acquired
    mock.assert_equals(calls.release, 0, "impl.release not called when not held")
    mock.assert_equals(lock:is_held(), false, "still not held")
end)

-- ============================================================
-- Slice 6: double release is idempotent
-- ============================================================

run_test("double release idempotent: acquire, release, release -> impl.release once", function()
    local lock, calls = new_counting_lock()
    lock:acquire()
    lock:release()
    lock:release()  -- already released
    mock.assert_equals(calls.release, 1, "second release did not re-call impl")
    mock.assert_equals(lock:is_held(), false, "still not held")
end)

-- ============================================================
-- Slice 7: acquire->release->acquire cycle calls impl per transition
-- ============================================================

run_test("acquire->release->acquire cycle: each transition calls impl once", function()
    local lock, calls = new_counting_lock()
    lock:acquire()    -- acquire #1
    lock:release()    -- release #1
    lock:acquire()    -- acquire #2 (new held period)
    mock.assert_equals(calls.acquire, 2, "acquired twice (two held periods)")
    mock.assert_equals(calls.release, 1, "released once")
    mock.assert_equals(lock:is_held(), true, "held again")
end)

-- ============================================================
-- Slice 8: default impl (no opts.impl) never crashes on dev Mac
-- ============================================================

run_test("default impl: acquire/release never crash off-device; is_held reflects state", function()
    local lock = wake_lock.new({})  -- no impl -> guarded inkview probe (no-op on dev)
    local ok_a, err_a = pcall(function() lock:acquire() end)
    mock.assert_equals(ok_a, true, "default acquire does not crash: " .. tostring(err_a))
    mock.assert_equals(lock:is_held(), true, "held after default acquire")
    local ok_r, err_r = pcall(function() lock:release() end)
    mock.assert_equals(ok_r, true, "default release does not crash: " .. tostring(err_r))
    mock.assert_equals(lock:is_held(), false, "not held after default release")
end)

-- Summary
print(string.format("\n%d passed, %d failed", passed, failed))
if #errors > 0 then
    print("\nFailures:")
    for _, e in ipairs(errors) do
        print("  " .. e.name .. ": " .. e.err)
    end
    os.exit(1)
end
