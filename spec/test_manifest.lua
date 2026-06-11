-- Manifest CRUD tests
-- Tests manifest.lua public API: addBook, getBook
--
-- Run with: luajit spec/test_manifest.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

-- Stub KOReader dependencies that manifest.lua requires
-- These must be defined BEFORE requiring manifest.lua
local mock_settings = nil

-- Stub luasettings module
package.loaded["luasettings"] = {}
package.loaded["luasettings"].open = function(self, path)
    return mock_settings
end

-- Stub DataStorage
package.loaded["datastorage"] = {
    getSettingsDir = function()
        return "/tmp/koreader-test/settings"
    end,
}

-- Stub logger (manifest.lua will use abs_logger which requires "logger")
-- Use a recording stub so we can assert on warn() calls
local recorded_warnings = {}
package.loaded["logger"] = {
    dbg = function() end,
    info = function() end,
    warn = function(msg) table.insert(recorded_warnings, msg) end,
}

local mock = require("spec/test_helper")
local manifest = require("manifest")

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

-- ============================================================
-- Test: addBook stores entry and getBook retrieves it
-- ============================================================
run_test("addBook stores entry and getBook retrieves it", function()
    mock_settings = mock.create_lua_settings({})

    manifest.init()

    manifest.addBook({
        abs_item_id = "li_abc123",
        title = "Test Book",
        author = "Author",
        local_dir = "/tmp/test",
        files = {},
        current_time = 0,
        duration = 3600,
        chapters = {},
        is_finished = false,
        last_synced_at = 0,
    })

    local book = manifest.getBook("li_abc123")
    assert(book ~= nil, "getBook should return a book entry")
    mock.assert_equals(book.title, "Test Book", "title should match")
    mock.assert_equals(book.author, "Author", "author should match")
    mock.assert_equals(book.duration, 3600, "duration should match")
end)

-- ============================================================
-- Test: getBook returns nil for unknown item ID
-- ============================================================
run_test("getBook returns nil for unknown item ID", function()
    mock_settings = mock.create_lua_settings({})

    manifest.init()

    local book = manifest.getBook("nonexistent")
    mock.assert_equals(book, nil, "getBook should return nil for unknown ID")
end)

-- ============================================================
-- Test: getAllBooks returns all added entries
-- ============================================================
run_test("getAllBooks returns all added entries", function()
    manifest._resetSettings()
    mock_settings = mock.create_lua_settings({})

    manifest.init()

    manifest.addBook({
        abs_item_id = "li_book1",
        title = "Book One",
        author = "Author A",
        local_dir = "/tmp/book1",
        files = {},
        current_time = 0,
        duration = 3600,
        chapters = {},
        is_finished = false,
        last_synced_at = 0,
    })

    manifest.addBook({
        abs_item_id = "li_book2",
        title = "Book Two",
        author = "Author B",
        local_dir = "/tmp/book2",
        files = {},
        current_time = 0,
        duration = 7200,
        chapters = {},
        is_finished = false,
        last_synced_at = 0,
    })

    local all_books = manifest.getAllBooks()
    assert(all_books ~= nil, "getAllBooks should return a table")
    mock.assert_equals(#all_books, 2, "should return 2 books")

    -- Verify at least one entry has the correct title
    local found_one = false
    for _, b in ipairs(all_books) do
        if b.title == "Book One" then
            found_one = true
            break
        end
    end
    assert(found_one, "should find 'Book One' in results")
end)

-- ============================================================
-- Test: updateBook modifies specific fields
-- ============================================================
run_test("updateBook modifies specific fields", function()
    mock_settings = mock.create_lua_settings({})

    manifest.init()

    manifest.addBook({
        abs_item_id = "li_abc123",
        title = "Original",
        author = "Author",
        local_dir = "/tmp/test",
        files = {},
        current_time = 0,
        duration = 3600,
        chapters = {},
        is_finished = false,
        last_synced_at = 0,
    })

    manifest.updateBook("li_abc123", {title = "Updated", duration = 7200})

    local book = manifest.getBook("li_abc123")
    assert(book ~= nil, "book should still exist after update")
    mock.assert_equals(book.title, "Updated", "title should be updated")
    mock.assert_equals(book.duration, 7200, "duration should be updated")
    mock.assert_equals(book.author, "Author", "author should be preserved")
end)

-- ============================================================
-- Test: removeBook deletes entry and getBook returns nil
-- ============================================================
run_test("removeBook deletes entry and getBook returns nil", function()
    mock_settings = mock.create_lua_settings({})

    manifest.init()

    manifest.addBook({
        abs_item_id = "li_abc123",
        title = "Test Book",
        author = "Author",
        local_dir = "/tmp/test",
        files = {},
        current_time = 0,
        duration = 3600,
        chapters = {},
        is_finished = false,
        last_synced_at = 0,
    })

    manifest.removeBook("li_abc123")

    local book = manifest.getBook("li_abc123")
    mock.assert_equals(book, nil, "getBook should return nil after removeBook")
end)

-- ============================================================
-- Test: updateFileStatus changes status of a specific file
-- ============================================================
run_test("updateFileStatus changes status of a specific file", function()
    mock_settings = mock.create_lua_settings({})

    manifest.init()

    manifest.addBook({
        abs_item_id = "li_abc123",
        title = "Test Book",
        author = "Author",
        local_dir = "/tmp/test",
        files = {
            {filename = "part1.m4b", size = 1000, type = "audio", status = "pending"},
            {filename = "part2.m4b", size = 2000, type = "audio", status = "pending"},
        },
        current_time = 0,
        duration = 3600,
        chapters = {},
        is_finished = false,
        last_synced_at = 0,
    })

    manifest.updateFileStatus("li_abc123", "part1.m4b", "complete")

    local book = manifest.getBook("li_abc123")
    assert(book ~= nil, "book should exist")
    mock.assert_equals(book.files[1].status, "complete", "part1 status should be complete")
    mock.assert_equals(book.files[2].status, "pending", "part2 status should remain pending")
end)

-- ============================================================
-- Test: updatePosition updates current_time and is_finished
-- ============================================================
run_test("updatePosition updates current_time and is_finished", function()
    mock_settings = mock.create_lua_settings({})

    manifest.init()

    manifest.addBook({
        abs_item_id = "li_abc123",
        title = "Test Book",
        author = "Author",
        local_dir = "/tmp/test",
        files = {},
        current_time = 0,
        duration = 3600,
        chapters = {},
        is_finished = false,
        last_synced_at = 0,
    })

    manifest.updatePosition("li_abc123", 1800.5, false)

    local book = manifest.getBook("li_abc123")
    assert(book ~= nil, "book should exist")
    mock.assert_equals(book.current_time, 1800.5, "current_time should be 1800.5")
    mock.assert_equals(book.is_finished, false, "is_finished should be false")

    manifest.updatePosition("li_abc123", 3600, true)

    book = manifest.getBook("li_abc123")
    mock.assert_equals(book.current_time, 3600, "current_time should be 3600")
    mock.assert_equals(book.is_finished, true, "is_finished should be true")
end)

-- ============================================================
-- Test: getRecentBook returns book with highest current_time
-- ============================================================
run_test("getRecentBook returns book with highest current_time", function()
    manifest._resetSettings()
    mock_settings = mock.create_lua_settings({})

    manifest.init()

    manifest.addBook({
        abs_item_id = "li_book1",
        title = "Book One",
        author = "Author A",
        local_dir = "/tmp/book1",
        files = {},
        current_time = 500,
        duration = 3600,
        chapters = {},
        is_finished = false,
        last_synced_at = 0,
    })

    manifest.addBook({
        abs_item_id = "li_book2",
        title = "Book Two",
        author = "Author B",
        local_dir = "/tmp/book2",
        files = {},
        current_time = 1800,
        duration = 7200,
        chapters = {},
        is_finished = false,
        last_synced_at = 0,
    })

    manifest.addBook({
        abs_item_id = "li_book3",
        title = "Book Three",
        author = "Author C",
        local_dir = "/tmp/book3",
        files = {},
        current_time = 3000,
        duration = 5400,
        chapters = {},
        is_finished = false,
        last_synced_at = 0,
    })

    local recent = manifest.getRecentBook()
    assert(recent ~= nil, "getRecentBook should return a book")
    mock.assert_equals(recent.abs_item_id, "li_book3", "should return book with highest current_time")
    mock.assert_equals(recent.current_time, 3000, "current_time should be 3000")
end)

-- ============================================================
-- Test: getRecentBook returns nil when no books exist
-- ============================================================
run_test("getRecentBook returns nil when no books exist", function()
    manifest._resetSettings()
    mock_settings = mock.create_lua_settings({})

    manifest.init()

    local recent = manifest.getRecentBook()
    mock.assert_equals(recent, nil, "getRecentBook should return nil with no books")
end)

-- ============================================================
-- Slice 4: Manifest helper queries
-- ============================================================

run_test("isDownloaded returns true when all files complete", function()
    mock_settings = mock.create_lua_settings({})
    manifest.init()

    manifest.addBook({
        abs_item_id = "li_abc123",
        title = "Test Book",
        author = "Author",
        local_dir = "/tmp/test",
        files = {
            {filename = "part1.m4b", size = 1000, type = "audio", status = "complete"},
            {filename = "part2.m4b", size = 2000, type = "audio", status = "complete"},
        },
        current_time = 0,
        duration = 3600,
        chapters = {},
        is_finished = false,
        last_synced_at = 0,
    })

    mock.assert_equals(manifest.isDownloaded("li_abc123"), true, "all complete → downloaded")
end)

run_test("isDownloaded returns false when some files pending", function()
    mock_settings = mock.create_lua_settings({})
    manifest.init()

    manifest.addBook({
        abs_item_id = "li_abc123",
        title = "Test Book",
        author = "Author",
        local_dir = "/tmp/test",
        files = {
            {filename = "part1.m4b", size = 1000, type = "audio", status = "complete"},
            {filename = "part2.m4b", size = 2000, type = "audio", status = "pending"},
        },
        current_time = 0,
        duration = 3600,
        chapters = {},
        is_finished = false,
        last_synced_at = 0,
    })

    mock.assert_equals(manifest.isDownloaded("li_abc123"), false, "some pending → not downloaded")
end)

run_test("isDownloaded returns false for unknown book", function()
    mock_settings = mock.create_lua_settings({})
    manifest.init()

    mock.assert_equals(manifest.isDownloaded("nonexistent"), false, "unknown → not downloaded")
end)

run_test("hasIncompleteFiles returns true for partial files", function()
    mock_settings = mock.create_lua_settings({})
    manifest.init()

    manifest.addBook({
        abs_item_id = "li_abc123",
        title = "Test Book",
        author = "Author",
        local_dir = "/tmp/test",
        files = {
            {filename = "part1.m4b", size = 1000, type = "audio", status = "partial"},
        },
        current_time = 0,
        duration = 3600,
        chapters = {},
        is_finished = false,
        last_synced_at = 0,
    })

    mock.assert_equals(manifest.hasIncompleteFiles("li_abc123"), true, "partial → incomplete")
end)

run_test("hasIncompleteFiles returns false for all complete", function()
    mock_settings = mock.create_lua_settings({})
    manifest.init()

    manifest.addBook({
        abs_item_id = "li_abc123",
        title = "Test Book",
        author = "Author",
        local_dir = "/tmp/test",
        files = {
            {filename = "part1.m4b", size = 1000, type = "audio", status = "complete"},
        },
        current_time = 0,
        duration = 3600,
        chapters = {},
        is_finished = false,
        last_synced_at = 0,
    })

    mock.assert_equals(manifest.hasIncompleteFiles("li_abc123"), false, "all complete → not incomplete")
end)

run_test("getIncompleteFiles returns only pending/partial files", function()
    mock_settings = mock.create_lua_settings({})
    manifest.init()

    manifest.addBook({
        abs_item_id = "li_abc123",
        title = "Test Book",
        author = "Author",
        local_dir = "/tmp/test",
        files = {
            {filename = "part1.m4b", size = 1000, type = "audio", status = "complete"},
            {filename = "part2.m4b", size = 2000, type = "audio", status = "pending"},
            {filename = "part3.m4b", size = 3000, type = "audio", status = "partial"},
        },
        current_time = 0,
        duration = 3600,
        chapters = {},
        is_finished = false,
        last_synced_at = 0,
    })

    local incomplete = manifest.getIncompleteFiles("li_abc123")
    mock.assert_equals(#incomplete, 2, "two incomplete files")
    mock.assert_equals(incomplete[1].filename, "part2.m4b", "first incomplete")
    mock.assert_equals(incomplete[2].filename, "part3.m4b", "second incomplete")
end)

run_test("getTotalFileSize returns sum of all file sizes", function()
    mock_settings = mock.create_lua_settings({})
    manifest.init()

    manifest.addBook({
        abs_item_id = "li_abc123",
        title = "Test Book",
        author = "Author",
        local_dir = "/tmp/test",
        files = {
            {filename = "part1.m4b", size = 1000, type = "audio", status = "complete"},
            {filename = "part2.m4b", size = 2000, type = "audio", status = "pending"},
        },
        current_time = 0,
        duration = 3600,
        chapters = {},
        is_finished = false,
        last_synced_at = 0,
    })

    mock.assert_equals(manifest.getTotalFileSize("li_abc123"), 3000, "1000 + 2000 = 3000")
end)

run_test("getDownloadedSize returns sum of complete file sizes", function()
    mock_settings = mock.create_lua_settings({})
    manifest.init()

    manifest.addBook({
        abs_item_id = "li_abc123",
        title = "Test Book",
        author = "Author",
        local_dir = "/tmp/test",
        files = {
            {filename = "part1.m4b", size = 1000, type = "audio", status = "complete"},
            {filename = "part2.m4b", size = 2000, type = "audio", status = "pending"},
        },
        current_time = 0,
        duration = 3600,
        chapters = {},
        is_finished = false,
        last_synced_at = 0,
    })

    mock.assert_equals(manifest.getDownloadedSize("li_abc123"), 1000, "only complete file")
end)

-- ============================================================
-- Regression: manifest.init() must not discard in-memory state
-- Bug: init() used to re-open LuaSettings from disk, losing
-- addBook/updateFileStatus changes that hadn't been flushed.
-- Fix: init() is now idempotent (no-op after first call).
-- ============================================================
run_test("init() is idempotent: second call does not discard data", function()
    mock_settings = mock.create_lua_settings({})
    manifest._resetSettings()  -- allow init to run fresh

    manifest.init()

    manifest.addBook({
        abs_item_id = "li_reinit_test",
        title = "Reinit Test",
        author = "Author",
        local_dir = "/tmp/reinit",
        files = {
            { filename = "test.m4b", ino = 1, size = 100, type = "audio", status = "pending" },
        },
        current_time = 0,
        duration = 3600,
        chapters = {},
        is_finished = false,
        last_synced_at = 0,
    })

    -- Simulate what happens after download: updateFileStatus, then init()
    manifest.updateFileStatus("li_reinit_test", "test.m4b", "complete")

    -- Before fix, this would re-read from disk and lose everything
    manifest.init()

    local book = manifest.getBook("li_reinit_test")
    assert(book ~= nil, "getBook should still find the book after init()")
    mock.assert_equals(book.title, "Reinit Test", "title should survive init()")

    -- isDownloaded should return true since the file is complete
    mock.assert_equals(manifest.isDownloaded("li_reinit_test"), true,
        "isDownloaded should return true after updateFileStatus + init()")

    -- Verify file status survived
    mock.assert_equals(book.files[1].status, "complete",
        "file status should be 'complete' after init()")
end)

run_test("_resetSettings allows init to re-run", function()
    mock_settings = mock.create_lua_settings({})
    manifest._resetSettings()

    manifest.init()
    manifest.addBook({
        abs_item_id = "li_reset_test",
        title = "Reset Test",
        author = "A",
        local_dir = "/tmp/reset",
        files = {},
        current_time = 0,
        duration = 0,
        chapters = {},
        is_finished = false,
        last_synced_at = 0,
    })

    -- Reset and re-init with fresh settings
    manifest._resetSettings()
    mock_settings = mock.create_lua_settings({})
    manifest.init()

    local book = manifest.getBook("li_reset_test")
    assert(book == nil, "getBook should return nil after reset with fresh settings")
end)

-- ============================================================
-- Slice 5: Manifest mutation functions warn on miss (Issue #27)
-- ============================================================

run_test("updateBook warns when given nonexistent ID", function()
    -- Clear recorded warnings before test
    while #recorded_warnings > 0 do table.remove(recorded_warnings) end

    mock_settings = mock.create_lua_settings({})
    manifest._resetSettings()
    manifest.init()

    -- Do NOT add any book — call updateBook with a nonexistent ID
    local result = manifest.updateBook("nonexistent", {title = "Updated"})

    -- Should have emitted exactly one warning
    mock.assert_equals(#recorded_warnings, 1,
        "updateBook should emit one warning for nonexistent ID")
    mock.assert_equals(string.find(recorded_warnings[1], "nonexistent") ~= nil, true,
        "warning should mention the ID that was not found")
end)

run_test("updateBook warns when given nil ID", function()
    while #recorded_warnings > 0 do table.remove(recorded_warnings) end

    mock_settings = mock.create_lua_settings({})
    manifest._resetSettings()
    manifest.init()

    local result = manifest.updateBook(nil, {title = "Updated"})

    mock.assert_equals(#recorded_warnings, 1,
        "updateBook should emit one warning for nil ID")
end)

run_test("updateFileStatus warns when book not found", function()
    while #recorded_warnings > 0 do table.remove(recorded_warnings) end

    mock_settings = mock.create_lua_settings({})
    manifest._resetSettings()
    manifest.init()

    local result = manifest.updateFileStatus("nonexistent", "part1.m4b", "complete")

    mock.assert_equals(#recorded_warnings, 1,
        "updateFileStatus should emit one warning for nonexistent book ID")
end)

run_test("updateFileStatus warns when file not found in book", function()
    while #recorded_warnings > 0 do table.remove(recorded_warnings) end

    mock_settings = mock.create_lua_settings({})
    manifest._resetSettings()
    manifest.init()

    manifest.addBook({
        abs_item_id = "li_abc123",
        title = "Test Book",
        author = "Author",
        local_dir = "/tmp/test",
        files = {
            {filename = "part1.m4b", size = 1000, type = "audio", status = "pending"},
        },
        current_time = 0,
        duration = 3600,
        chapters = {},
        is_finished = false,
        last_synced_at = 0,
    })

    -- Update a filename that doesn't exist in this book
    local result = manifest.updateFileStatus("li_abc123", "missing.m4b", "complete")

    mock.assert_equals(#recorded_warnings, 1,
        "updateFileStatus should emit one warning for nonexistent filename")
end)

run_test("updatePosition warns when book not found", function()
    while #recorded_warnings > 0 do table.remove(recorded_warnings) end

    mock_settings = mock.create_lua_settings({})
    manifest._resetSettings()
    manifest.init()

    local result = manifest.updatePosition("nonexistent", 100, false)

    mock.assert_equals(#recorded_warnings, 1,
        "updatePosition should emit one warning for nonexistent ID")
end)

run_test("mutation functions do NOT warn for valid IDs", function()
    while #recorded_warnings > 0 do table.remove(recorded_warnings) end

    mock_settings = mock.create_lua_settings({})
    manifest._resetSettings()
    manifest.init()

    manifest.addBook({
        abs_item_id = "li_valid",
        title = "Valid Book",
        author = "Author",
        local_dir = "/tmp/test",
        files = {
            {filename = "part1.m4b", size = 1000, type = "audio", status = "pending"},
        },
        current_time = 0,
        duration = 3600,
        chapters = {},
        is_finished = false,
        last_synced_at = 0,
    })

    -- All valid operations — should produce zero warnings
    manifest.updateBook("li_valid", {title = "Updated"})
    manifest.updateFileStatus("li_valid", "part1.m4b", "complete")
    manifest.updatePosition("li_valid", 100, false)

    mock.assert_equals(#recorded_warnings, 0,
        "no warnings should be emitted for valid operations")
end)

run_test("flush() is called by addBook (mock verify)", function()
    local flush_count = 0
    mock_settings = mock.create_lua_settings({})
    -- Override flush to count calls
    mock_settings.flush = function(self) flush_count = flush_count + 1 end
    manifest._resetSettings()
    manifest.init()

    manifest.addBook({
        abs_item_id = "li_flush_test",
        title = "Flush Test",
        author = "A",
        local_dir = "/tmp/flush",
        files = {},
        current_time = 0,
        duration = 0,
        chapters = {},
        is_finished = false,
        last_synced_at = 0,
    })

    mock.assert_equals(flush_count, 1, "addBook should call flush once")
end)

-- ============================================================
-- Slice 6: Higher-order file-iteration helpers (Issue #29)
-- ============================================================

run_test("_filter_files returns files matching predicate", function()
    mock_settings = mock.create_lua_settings({})
    manifest._resetSettings()
    manifest.init()

    manifest.addBook({
        abs_item_id = "li_filter_test",
        title = "Filter Test",
        author = "A",
        local_dir = "/tmp/filter",
        files = {
            {filename = "a.m4b", size = 100, type = "audio", status = "complete"},
            {filename = "b.m4b", size = 200, type = "audio", status = "pending"},
            {filename = "c.m4b", size = 300, type = "audio", status = "partial"},
        },
        current_time = 0,
        duration = 0,
        chapters = {},
        is_finished = false,
        last_synced_at = 0,
    })

    local complete = manifest._filter_files("li_filter_test", function(f)
        return f.status == "complete"
    end)
    mock.assert_equals(#complete, 1, "one complete file")
    mock.assert_equals(complete[1].filename, "a.m4b", "should be the complete file")
end)

run_test("_filter_files returns empty array for no matches", function()
    mock_settings = mock.create_lua_settings({})
    manifest._resetSettings()
    manifest.init()

    manifest.addBook({
        abs_item_id = "li_nomatch",
        title = "No Match",
        author = "A",
        local_dir = "/tmp/nomatch",
        files = {
            {filename = "a.m4b", size = 100, type = "audio", status = "pending"},
        },
        current_time = 0,
        duration = 0,
        chapters = {},
        is_finished = false,
        last_synced_at = 0,
    })

    local result = manifest._filter_files("li_nomatch", function(f)
        return f.status == "complete"
    end)
    mock.assert_equals(#result, 0, "no matching files")
end)

-- ============================================================
-- Slice 6b: _reduce_files helper (Issue #29)
-- ============================================================

run_test("_reduce_files sums file sizes with reducer", function()
    mock_settings = mock.create_lua_settings({})
    manifest._resetSettings()
    manifest.init()

    manifest.addBook({
        abs_item_id = "li_reduce_test",
        title = "Reduce Test",
        author = "A",
        local_dir = "/tmp/reduce",
        files = {
            {filename = "a.m4b", size = 100, type = "audio", status = "complete"},
            {filename = "b.m4b", size = 200, type = "audio", status = "pending"},
            {filename = "c.m4b", size = 300, type = "audio", status = "partial"},
        },
        current_time = 0,
        duration = 0,
        chapters = {},
        is_finished = false,
        last_synced_at = 0,
    })

    local total = manifest._reduce_files("li_reduce_test", function(acc, f)
        return acc + f.size
    end, 0)
    mock.assert_equals(total, 600, "sum of all file sizes")
end)

run_test("_reduce_files returns init for nonexistent entry", function()
    mock_settings = mock.create_lua_settings({})
    manifest._resetSettings()
    manifest.init()

    local total = manifest._reduce_files("nonexistent", function(acc, f)
        return acc + f.size
    end, 42)
    mock.assert_equals(total, 42, "returns init value for missing entry")
end)

-- ============================================================
-- Slice 6c: Edge cases for _filter_files and _reduce_files (Issue #29)
-- ============================================================

run_test("_filter_files returns empty for nil entry", function()
    mock_settings = mock.create_lua_settings({})
    manifest._resetSettings()
    manifest.init()
    -- Don't add any book — entry is nil
    local result = manifest._filter_files("no_such_book", function(f)
        return true
    end)
    mock.assert_equals(#result, 0, "empty array for nil entry")
end)

run_test("_filter_files returns empty for empty files array", function()
    mock_settings = mock.create_lua_settings({})
    manifest._resetSettings()
    manifest.init()
    manifest.addBook({
        abs_item_id = "li_empty_files",
        title = "Empty Files",
        author = "A",
        local_dir = "/tmp/empty",
        files = {},
        current_time = 0,
        duration = 0,
        chapters = {},
        is_finished = false,
        last_synced_at = 0,
    })
    local result = manifest._filter_files("li_empty_files", function(f)
        return true
    end)
    mock.assert_equals(#result, 0, "empty array for no files")
end)

run_test("_filter_files handles missing status field gracefully", function()
    mock_settings = mock.create_lua_settings({})
    manifest._resetSettings()
    manifest.init()
    manifest.addBook({
        abs_item_id = "li_no_status",
        title = "No Status",
        author = "A",
        local_dir = "/tmp/nostatus",
        files = {
            {filename = "a.m4b", size = 100, type = "audio"},
            {filename = "b.m4b", size = 200, type = "audio", status = "complete"},
        },
        current_time = 0,
        duration = 0,
        chapters = {},
        is_finished = false,
        last_synced_at = 0,
    })
    -- Predicate checks for complete — only b.m4b matches
    local result = manifest._filter_files("li_no_status", function(f)
        return f.status == "complete"
    end)
    mock.assert_equals(#result, 1, "one file with status=complete")
    mock.assert_equals(result[1].filename, "b.m4b", "should be the one with status set")
end)

run_test("_reduce_files returns init for nil entry", function()
    mock_settings = mock.create_lua_settings({})
    manifest._resetSettings()
    manifest.init()
    local total = manifest._reduce_files("ghost", function(acc, f)
        return acc + 1
    end, 99)
    mock.assert_equals(total, 99, "init value for nil entry")
end)

run_test("_reduce_files returns init for empty files array", function()
    mock_settings = mock.create_lua_settings({})
    manifest._resetSettings()
    manifest.init()
    manifest.addBook({
        abs_item_id = "li_reduce_empty",
        title = "Reduce Empty",
        author = "A",
        local_dir = "/tmp/redempty",
        files = {},
        current_time = 0,
        duration = 0,
        chapters = {},
        is_finished = false,
        last_synced_at = 0,
    })
    local total = manifest._reduce_files("li_reduce_empty", function(acc, f)
        return acc + (f.size or 0)
    end, 0)
    mock.assert_equals(total, 0, "init value for empty files")
end)

run_test("_reduce_files handles mixed statuses and nil sizes", function()
    mock_settings = mock.create_lua_settings({})
    manifest._resetSettings()
    manifest.init()
    manifest.addBook({
        abs_item_id = "li_mixed_edge",
        title = "Mixed Edge",
        author = "A",
        local_dir = "/tmp/mixededge",
        files = {
            {filename = "a.m4b", type = "audio", status = "complete"},  -- size=nil
            {filename = "b.m4b", size = 250, type = "audio", status = "partial"},
            {filename = "c.epub", size = 500, type = "ebook"},  -- status=nil
        },
        current_time = 0,
        duration = 0,
        chapters = {},
        is_finished = false,
        last_synced_at = 0,
    })
    -- Sum all sizes (including nil-size treated as 0)
    local total = manifest._reduce_files("li_mixed_edge", function(acc, f)
        return acc + (f.size or 0)
    end, 0)
    mock.assert_equals(total, 750, "sum with nil sizes treated as 0")
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