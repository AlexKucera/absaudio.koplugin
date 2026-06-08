-- Cover cache tests
-- Tests cover_cache.lua public API: init, getCoverPath, hasCachedCover, fetchAndCache
--
-- Run with: luajit spec/test_cover_cache.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

-- Stub KOReader dependencies
package.loaded["logger"] = {
    dbg = function() end,
    info = function() end,
    warn = function() end,
}

package.loaded["abs_logger"] = {
    verbose = function() end,
    info = function() end,
    warn = function() end,
    set_level = function() end,
}

local mock = require("spec/test_helper")

-- Mock lfs for cover_cache module
-- luajit doesn't ship with lfs, so we provide a complete mock
local mock_file_system = {
    _existing_files = {},  -- set of file paths that "exist"
    _existing_dirs = {},   -- set of dir paths that "exist"
    _mkdir_called = {},    -- tracks mkdir calls
}
function mock_file_system.attributes(path, req)
    if req == "mode" then
        if mock_file_system._existing_files[path] then
            return "file"
        end
        if mock_file_system._existing_dirs[path] then
            return "directory"
        end
        return nil
    end
    return nil
end
function mock_file_system.mkdir(path)
    mock_file_system._mkdir_called[path] = true
    mock_file_system._existing_dirs[path] = true
    return true
end
function mock_file_system.dir(path)
    return function() end
end

package.loaded["lfs"] = mock_file_system

-- Mock api module
local mock_api = {
    _cover_sink = nil,
    _cover_ok = true,
    getCover = function(self, item_id, sink)
        mock_api._cover_sink = sink
        if mock_api._cover_ok then
            return true, 200
        end
        return false, {type = "network", message = "connection failed"}
    end,
    is_configured = function() return true end,
}
package.loaded["api"] = mock_api

local cover_cache = require("absaudio/cover_cache")

local passed = 0
local failed = 0
local errors = {}

local function run_test(name, fn)
    -- Reset mock state
    mock_file_system._existing_files = {}
    mock_file_system._existing_dirs = {}
    mock_file_system._mkdir_called = {}
    mock_api._cover_ok = true
    mock_api._cover_sink = nil

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
-- Test: getCoverPath returns correct path for an item
-- ============================================================
run_test("getCoverPath returns correct path for an item", function()
    cover_cache.init("/tmp/test-cache")
    local path = cover_cache.getCoverPath("item_abc123")
    mock.assert_equals(path, "/tmp/test-cache/item_abc123.jpg", "cover path should be {cache_dir}/{item_id}.jpg")
end)

-- ============================================================
-- Test: hasCachedCover returns false when no cover cached
-- ============================================================
run_test("hasCachedCover returns false when no cover cached", function()
    cover_cache.init("/tmp/test-cache-nonexistent")
    -- No files in mock fs
    local has = cover_cache.hasCachedCover("item_abc123")
    mock.assert_equals(has, false, "should return false when no file on disk")
end)

-- ============================================================
-- Test: hasCachedCover returns true when cover exists on disk
-- ============================================================
run_test("hasCachedCover returns true when cover exists on disk", function()
    cover_cache.init("/tmp/test-cache")
    -- Register file in mock fs
    mock_file_system._existing_files["/tmp/test-cache/item_abc123.jpg"] = true
    local has = cover_cache.hasCachedCover("item_abc123")
    mock.assert_equals(has, true, "should return true when file exists")
end)

-- ============================================================
-- Test: fetchAndCache creates directory and fetches cover from API
-- ============================================================
run_test("fetchAndCache creates directory and fetches cover from API", function()
    local test_dir = "/tmp/test-cache-new"
    cover_cache.init(test_dir)

    local original_getCover = mock_api.getCover
    mock_api.getCover = function(self, item_id, sink)
        sink("fake jpeg data")
        return true, 200
    end

    -- Mock io.open to capture data without writing to real disk
    local written_data = nil
    local written_path = nil
    local original_io_open = io.open
    io.open = function(path, mode)
        written_path = path
        return {
            write = function(self, data) written_data = data end,
            close = function(self) end,
        }
    end

    local ok, path = cover_cache.fetchAndCache("item_xyz")
    mock.assert_equals(ok, true, "fetchAndCache should succeed")
    mock.assert_equals(path, test_dir .. "/item_xyz.jpg", "should return cover path")
    mock.assert_equals(written_data, "fake jpeg data", "should write cover data to file")
    mock.assert_equals(written_path, test_dir .. "/item_xyz.jpg", "should open correct path")
    mock.assert_equals(mock_file_system._mkdir_called[test_dir], true, "should create cache dir")

    io.open = original_io_open
    mock_api.getCover = original_getCover
end)

-- ============================================================
-- Test: fetchAndCache returns false on API failure
-- ============================================================
run_test("fetchAndCache returns false on API failure", function()
    cover_cache.init("/tmp/test-cache")

    local original_io_open = io.open
    io.open = function(path, mode)
        return {
            write = function() end,
            close = function() end,
        }
    end

    local original_getCover = mock_api.getCover
    mock_api.getCover = function(self, item_id, sink)
        return false, {type = "network", message = "connection failed"}
    end

    local ok, err = cover_cache.fetchAndCache("item_fail")
    mock.assert_equals(ok, false, "fetchAndCache should return false on API failure")

    io.open = original_io_open
    mock_api.getCover = original_getCover
end)

-- ============================================================
-- Test: fetchAndCache skips fetch if cover already cached
-- ============================================================
run_test("fetchAndCache skips fetch if cover already cached", function()
    cover_cache.init("/tmp/test-cache")
    -- Register the file as cached in mock fs
    mock_file_system._existing_files["/tmp/test-cache/item_cached.jpg"] = true

    local api_called = false
    local original_getCover = mock_api.getCover
    mock_api.getCover = function()
        api_called = true
        return true, 200
    end

    local ok, path = cover_cache.fetchAndCache("item_cached")
    mock.assert_equals(ok, true, "should succeed from cache")
    mock.assert_equals(path, "/tmp/test-cache/item_cached.jpg", "should return cached path")
    mock.assert_equals(api_called, false, "should NOT call API when cached")

    mock_api.getCover = original_getCover
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
