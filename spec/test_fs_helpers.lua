-- fs_helpers tests
-- Tests absaudio/fs_helpers.lua public API: mkdir_p, get_file_size, delete_file, delete_dir
--
-- Run with: luajit spec/test_fs_helpers.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

------------------------------------------------------------------------
-- Mock lfs (LuaFileSystem) — luajit doesn't ship with it
------------------------------------------------------------------------
local mock_lfs = {
    _dirs = {},      -- set of paths that exist as directories
    _files = {},     -- set of paths that exist as files
    _mkdir_log = {}, -- tracks mkdir calls
    _rmdir_log = {}, -- tracks rmdir calls
}

function mock_lfs.reset()
    mock_lfs._dirs = {}
    mock_lfs._files = {}
    mock_lfs._mkdir_log = {}
    mock_lfs._rmdir_log = {}
end

function mock_lfs.attributes(path, req)
    if mock_lfs._dirs[path] then
        if req == "mode" then return "directory" end
        if req == "size" then return mock_lfs._dirs[path] end
        return { mode = "directory" }
    end
    if mock_lfs._files[path] then
        if req == "mode" then return "file" end
        if req == "size" then return mock_lfs._files[path] end
        return { mode = "file", size = mock_lfs._files[path] }
    end
    return nil
end

function mock_lfs.mkdir(path)
    mock_lfs._mkdir_log[path] = (mock_lfs._mkdir_log[path] or 0) + 1
    mock_lfs._dirs[path] = 0  -- directory entries have size 0
    return true
end

function mock_lfs.rmdir(path)
    mock_lfs._rmdir_log[path] = (mock_lfs._rmdir_log[path] or 0) + 1
    mock_lfs._dirs[path] = nil
    return true
end

function mock_lfs.dir(path)
    if mock_lfs._dirs[path] then
        local function iter() return nil end
        return iter
    end
    return nil
end

mock_lfs.reset()

package.loaded["lfs"] = mock_lfs
_G.lfs = mock_lfs

-- Mock logger/abs_logger (required by fs_helpers)
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

-- Mock os.remove for delete_file tests
local _orig_os_remove = os.remove
local os_remove_log = {}
os.remove = function(path)
    table.insert(os_remove_log, path)
    mock_lfs._files[path] = nil
    return true
end

------------------------------------------------------------------------
-- Require module under test
------------------------------------------------------------------------
local fs_helpers = require("absaudio/fs_helpers")
local mock = require("spec/test_helper")

------------------------------------------------------------------------
-- Test runner
------------------------------------------------------------------------
local passed = 0
local failed = 0
local errors = {}

local function run_test(name, fn)
    -- Reset mock state before each test
    mock_lfs.reset()
    os_remove_log = {}

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
-- Test: mkdir_p creates a single-level directory
-- ============================================================
run_test("mkdir_p creates a single-level directory", function()
    local ok, err = fs_helpers.mkdir_p("/tmp/test-single-dir")

    mock.assert_equals(ok, true, "should return true on success")
    mock.assert_equals(err, nil, "should return nil error on success")
    mock.assert_equals(mock_lfs._mkdir_log["/tmp/test-single-dir"] ~= nil, true,
        "should call lfs.mkdir for the target directory")
end)

-- ============================================================
-- Test: mkdir_p is idempotent when directory already exists
-- ============================================================
run_test("mkdir_p is idempotent when directory already exists", function()
    -- Pre-register the directory as existing
    mock_lfs._dirs["/tmp/existing-dir"] = 0

    local ok, err = fs_helpers.mkdir_p("/tmp/existing-dir")

    mock.assert_equals(ok, true, "should return true for existing dir")
    mock.assert_equals(err, nil, "should return nil error")
    mock.assert_equals(mock_lfs._mkdir_log["/tmp/existing-dir"], nil,
        "should NOT call lfs.mkdir when dir already exists")
end)

-- ============================================================
-- Test: mkdir_p creates nested directories recursively
-- ============================================================
run_test("mkdir_p creates nested directories recursively", function()
    local ok, err = fs_helpers.mkdir_p("/tmp/a/b/c/deep")

    mock.assert_equals(ok, true, "should succeed creating nested dirs")
    mock.assert_equals(mock_lfs._mkdir_log["/tmp"] ~= nil, true, "should create /tmp")
    mock.assert_equals(mock_lfs._mkdir_log["/tmp/a"] ~= nil, true, "should create /tmp/a")
    mock.assert_equals(mock_lfs._mkdir_log["/tmp/a/b"] ~= nil, true, "should create /tmp/a/b")
    mock.assert_equals(mock_lfs._mkdir_log["/tmp/a/b/c"] ~= nil, true, "should create /tmp/a/b/c")
    mock.assert_equals(mock_lfs._mkdir_log["/tmp/a/b/c/deep"] ~= nil, true, "should create /tmp/a/b/c/deep")
end)

-- ============================================================
-- Test: mkdir_p returns error for nil path
-- ============================================================
run_test("mkdir_p returns error for nil path", function()
    local ok, err = fs_helpers.mkdir_p(nil)

    mock.assert_equals(ok, false, "should return false for nil path")
    mock.assert_equals(err ~= nil, true, "should return error info for nil path")
    mock.assert_equals(err.type, "io", "error type should be 'io'")
end)

-- ============================================================
-- Test: mkdir_p returns error for empty string
-- ============================================================
run_test("mkdir_p returns error for empty string", function()
    local ok, err = fs_helpers.mkdir_p("")

    mock.assert_equals(ok, false, "should return false for empty path")
    mock.assert_equals(err ~= nil, true, "should return error info for empty path")
    mock.assert_equals(err.type, "io", "error type should be 'io'")
end)

-- ============================================================
-- Test: get_file_size returns size for existing file
-- ============================================================
run_test("get_file_size returns size for existing file", function()
    mock_lfs._files["/tmp/test.txt"] = 1024

    local size = fs_helpers.get_file_size("/tmp/test.txt")

    mock.assert_equals(size, 1024, "should return file size in bytes")
end)

-- ============================================================
-- Test: get_file_size returns nil for non-existent file
-- ============================================================
run_test("get_file_size returns nil for non-existent file", function()
    local size = fs_helpers.get_file_size("/tmp/no-such-file.txt")

    mock.assert_equals(size, nil, "should return nil for missing file")
end)

-- ============================================================
-- Test: get_file_size returns nil for nil input
-- ============================================================
run_test("get_file_size returns nil for nil input", function()
    local size = fs_helpers.get_file_size(nil)

    mock.assert_equals(size, nil, "should return nil for nil path")
end)

-- ============================================================
-- Test: delete_file calls os.remove and returns true
-- ============================================================
run_test("delete_file calls os.remove and returns true", function()
    local ok = fs_helpers.delete_file("/tmp/delete-me.txt")

    mock.assert_equals(ok, true, "should return true on success")
    mock.assert_equals(#os_remove_log, 1, "should call os.remove once")
    mock.assert_equals(os_remove_log[1], "/tmp/delete-me.txt", "should pass correct path to os.remove")
end)

-- ============================================================
-- Test: delete_file returns false for nil path
-- ============================================================
run_test("delete_file returns false for nil path", function()
    local ok = fs_helpers.delete_file(nil)

    mock.assert_equals(ok, false, "should return false for nil path")
end)

-- ============================================================
-- Test: delete_dir calls lfs.rmdir and returns true
-- ============================================================
run_test("delete_dir calls lfs.rmdir and returns true", function()
    mock_lfs._dirs["/tmp/empty-dir"] = 0

    local ok = fs_helpers.delete_dir("/tmp/empty-dir")

    mock.assert_equals(ok, true, "should return true on success")
    mock.assert_equals(mock_lfs._rmdir_log["/tmp/empty-dir"] ~= nil, true,
        "should call lfs.rmdir for the directory")
end)

-- ============================================================
-- Test: delete_dir returns false for nil path
-- ============================================================
run_test("delete_dir returns false for nil path", function()
    local ok = fs_helpers.delete_dir(nil)

    mock.assert_equals(ok, false, "should return false for nil path")
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
