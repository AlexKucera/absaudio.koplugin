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
package.loaded["logger"] = {
    dbg = function() end,
    info = function() end,
    warn = function() end,
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
