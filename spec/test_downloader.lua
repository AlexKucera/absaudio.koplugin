-- Downloader module tests
-- Tests sanitize_filename, format preference filter, file selection logic
--
-- Run with: luajit spec/test_downloader.lua

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
}

local mock = require("spec/test_helper")
local downloader = require("absaudio/downloader")

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
-- Slice 1: sanitize_filename
-- ============================================================

run_test("sanitize_filename strips colons", function()
    mock.assert_equals(downloader.sanitize_filename("Book: Title.m4b"), "Book_ Title.m4b", "colon → underscore")
end)

run_test("sanitize_filename strips forward slashes", function()
    mock.assert_equals(downloader.sanitize_filename("Part 1/File.m4b"), "Part 1_File.m4b", "slash → underscore")
end)

run_test("sanitize_filename strips backslashes", function()
    mock.assert_equals(downloader.sanitize_filename("Dir\\File.m4b"), "Dir_File.m4b", "backslash → underscore")
end)

run_test("sanitize_filename strips angle brackets and pipes", function()
    mock.assert_equals(downloader.sanitize_filename("<>|.m4b"), "___.m4b", "<>| → underscores")
end)

run_test("sanitize_filename strips double quotes and question marks", function()
    mock.assert_equals(downloader.sanitize_filename('What?"No".m4b'), "What__No_.m4b", "quotes and ? → underscores")
end)

run_test("sanitize_filename strips asterisks", function()
    mock.assert_equals(downloader.sanitize_filename("file*name.m4b"), "file_name.m4b", "* → underscore")
end)

run_test("sanitize_filename strips leading/trailing spaces and dots", function()
    mock.assert_equals(downloader.sanitize_filename(" .file.m4b. "), "file.m4b", "leading/trailing spaces and dots stripped")
end)

run_test("sanitize_filename returns safe name unchanged", function()
    mock.assert_equals(downloader.sanitize_filename("Clean File Name.m4b"), "Clean File Name.m4b", "safe name unchanged")
end)

run_test("sanitize_filename handles empty string", function()
    mock.assert_equals(downloader.sanitize_filename(""), "untitled", "empty → untitled")
end)

run_test("sanitize_filename handles all-special-chars", function()
    mock.assert_equals(downloader.sanitize_filename(':<>|?*\\'), "untitled", "all-special → untitled")
end)

-- ============================================================
-- Slice 2: filter_audio_files (format preference)
-- ============================================================

run_test("filter_audio_files returns only m4b when preferred", function()
    local files = {
        {filename = "book.m4b", ext = ".m4b", size = 1000},
        {filename = "book.mp3", ext = ".mp3", size = 2000},
    }
    local result = downloader.filter_audio_files(files, "m4b")
    mock.assert_equals(#result, 1, "only m4b files")
    mock.assert_equals(result[1].filename, "book.m4b", "should be the m4b file")
end)

run_test("filter_audio_files falls back to mp3 when no m4b", function()
    local files = {
        {filename = "book.mp3", ext = ".mp3", size = 2000},
        {filename = "book.ogg", ext = ".ogg", size = 3000},
    }
    local result = downloader.filter_audio_files(files, "m4b")
    mock.assert_equals(#result, 1, "only mp3 files")
    mock.assert_equals(result[1].filename, "book.mp3", "should be the mp3 file")
end)

run_test("filter_audio_files returns all audio when preferred format absent", function()
    local files = {
        {filename = "book.flac", ext = ".flac", size = 4000},
        {filename = "book.ogg", ext = ".ogg", size = 3000},
    }
    local result = downloader.filter_audio_files(files, "m4b")
    mock.assert_equals(#result, 2, "all audio files as fallback")
end)

run_test("filter_audio_files with mp3 preference returns mp3 only", function()
    local files = {
        {filename = "book.m4b", ext = ".m4b", size = 1000},
        {filename = "book.mp3", ext = ".mp3", size = 2000},
    }
    local result = downloader.filter_audio_files(files, "mp3")
    mock.assert_equals(#result, 1, "only mp3 files")
    mock.assert_equals(result[1].filename, "book.mp3", "should be the mp3 file")
end)

run_test("filter_audio_files with empty list returns empty", function()
    local result = downloader.filter_audio_files({}, "m4b")
    mock.assert_equals(#result, 0, "empty input → empty output")
end)

run_test("filter_audio_files preserves original file fields", function()
    local files = {
        {filename = "book.m4b", ext = ".m4b", size = 500000, ino = "12345", duration = 3600},
    }
    local result = downloader.filter_audio_files(files, "m4b")
    mock.assert_equals(result[1].size, 500000, "size preserved")
    mock.assert_equals(result[1].ino, "12345", "ino preserved")
    mock.assert_equals(result[1].duration, 3600, "duration preserved")
end)

-- ============================================================
-- Slice 3: select_files_to_download
-- ============================================================

run_test("select_files_to_download returns all pending files", function()
    local files = {
        {filename = "book.m4b", size = 1000, type = "audio", status = "pending"},
    }
    local result = downloader.select_files_to_download(files)
    mock.assert_equals(#result, 1, "one file to download")
    mock.assert_equals(result[1].status, "pending", "status is pending")
end)

run_test("select_files_to_download skips complete files", function()
    local files = {
        {filename = "book.m4b", size = 1000, type = "audio", status = "complete"},
        {filename = "book2.m4b", size = 2000, type = "audio", status = "pending"},
    }
    local result = downloader.select_files_to_download(files)
    mock.assert_equals(#result, 1, "only pending file")
    mock.assert_equals(result[1].filename, "book2.m4b", "should be the pending file")
end)

run_test("select_files_to_download includes partial files for resume", function()
    local files = {
        {filename = "book.m4b", size = 5000, type = "audio", status = "partial"},
        {filename = "book2.m4b", size = 2000, type = "audio", status = "pending"},
    }
    local result = downloader.select_files_to_download(files)
    mock.assert_equals(#result, 2, "both partial and pending")
end)

run_test("select_files_to_download returns empty when all complete", function()
    local files = {
        {filename = "book.m4b", size = 1000, type = "audio", status = "complete"},
    }
    local result = downloader.select_files_to_download(files)
    mock.assert_equals(#result, 0, "nothing to download")
end)

run_test("select_files_to_download with nil files returns empty", function()
    local result = downloader.select_files_to_download(nil)
    mock.assert_equals(#result, 0, "nil input → empty output")
end)

-- ============================================================
-- Slice 5: calculate_download_size & check_free_space
-- ============================================================

run_test("calculate_download_size sums pending/partial file sizes", function()
    local files = {
        {filename = "a.m4b", size = 1000, status = "pending"},
        {filename = "b.m4b", size = 2000, status = "complete"},
        {filename = "c.m4b", size = 3000, status = "partial"},
    }
    mock.assert_equals(downloader.calculate_download_size(files), 4000, "1000 + 3000 = 4000")
end)

run_test("calculate_download_size returns 0 for empty list", function()
    mock.assert_equals(downloader.calculate_download_size({}), 0, "empty → 0")
end)

run_test("calculate_download_size returns 0 for nil", function()
    mock.assert_equals(downloader.calculate_download_size(nil), 0, "nil → 0")
end)

run_test("check_free_space returns true when enough space", function()
    -- 100 bytes needed, 10000 available
    local result = downloader.check_free_space(100, 10000)
    mock.assert_equals(result, true, "enough space")
end)

run_test("check_free_space returns false when not enough space", function()
    -- 10000 bytes needed, 100 available
    local result = downloader.check_free_space(10000, 100)
    mock.assert_equals(result, false, "not enough space")
end)

run_test("check_free_space returns true when no download needed", function()
    local result = downloader.check_free_space(0, 0)
    mock.assert_equals(result, true, "0 bytes needed → always ok")
end)

-- ============================================================
-- Slice 6: prepare_download (manifest entry creation)
-- ============================================================

run_test("prepare_download creates manifest entry with filtered audio files", function()
    -- Mock manifest
    local added_entry = nil
    local mock_manifest = {
        getBook = function() return nil end,
        addBook = function(entry) added_entry = entry end,
        isDownloaded = function() return false end,
    }

    -- Mock config
    local mock_config = {
        get = function(key)
            if key == "download_dir" then return "/tmp/audiobooks" end
            if key == "preferred_format" then return "m4b" end
            return nil
        end,
    }

    local item = {
        id = "li_test1",
        media = {
            metadata = { title = "My Book", authorName = "Author" },
            audioFiles = {
                { ino = "111", metadata = { filename = "book.m4b", ext = ".m4b", size = 500000 }, duration = 3600 },
            },
            chapters = {{ id = 1, start = 0, ["end"] = 3600, title = "Ch 1" }},
            duration = 3600,
        },
    }

    local ok, result = downloader.prepare_download(item, mock_manifest, mock_config)
    assert(ok, "prepare_download should succeed")
    assert(added_entry ~= nil, "should have added manifest entry")
    mock.assert_equals(added_entry.abs_item_id, "li_test1")
    mock.assert_equals(added_entry.title, "My Book")
    mock.assert_equals(added_entry.author, "Author")
    mock.assert_equals(added_entry.local_dir, "/tmp/audiobooks/Author_My Book")
    mock.assert_equals(#added_entry.files, 1)
    mock.assert_equals(added_entry.files[1].filename, "book.m4b")
    mock.assert_equals(added_entry.files[1].size, 500000)
    mock.assert_equals(added_entry.files[1].type, "audio")
    mock.assert_equals(added_entry.files[1].status, "pending")
end)

run_test("prepare_download returns error when book already downloaded", function()
    local mock_manifest = {
        getBook = function() return { id = "li_test1" } end,
        isDownloaded = function() return true end,
    }
    local mock_config = { get = function() return "/tmp" end }

    local item = { id = "li_test1", media = { metadata = {} } }
    local ok, err = downloader.prepare_download(item, mock_manifest, mock_config)
    mock.assert_equals(ok, false, "should fail")
    mock.assert_equals(err, "already_downloaded", "error type")
end)

run_test("prepare_download returns error when no audio files", function()
    local mock_manifest = {
        getBook = function() return nil end,
        addBook = function() end,
        isDownloaded = function() return false end,
    }
    local mock_config = { get = function() return "/tmp" end }

    local item = { id = "li_test1", media = { metadata = { title = "No Audio" }, audioFiles = {} } }
    local ok, err = downloader.prepare_download(item, mock_manifest, mock_config)
    mock.assert_equals(ok, false, "should fail")
    mock.assert_equals(err, "no_audio_files", "error type")
end)

run_test("prepare_download sanitizes directory name", function()
    local added_entry = nil
    local mock_manifest = {
        getBook = function() return nil end,
        addBook = function(entry) added_entry = entry end,
        isDownloaded = function() return false end,
    }
    local mock_config = {
        get = function(key)
            if key == "download_dir" then return "/tmp/audiobooks" end
            if key == "preferred_format" then return "m4b" end
            return nil
        end,
    }

    local item = {
        id = "li_test2",
        media = {
            metadata = { title = "Book: Subtitle", authorName = "An Author" },
            audioFiles = {
                { ino = "111", metadata = { filename = "book.m4b", ext = ".m4b", size = 1000 }, duration = 100 },
            },
            chapters = {},
            duration = 100,
        },
    }

    local ok = downloader.prepare_download(item, mock_manifest, mock_config)
    assert(ok, "should succeed")
    -- Directory name should have colon replaced
    mock.assert_equals(added_entry.local_dir, "/tmp/audiobooks/An Author_Book_ Subtitle")
end)

-- ============================================================
-- Slice 7: build_range_header (resume partial downloads)
-- ============================================================

run_test("build_range_header returns nil for pending file (no resume)", function()
    local file = { filename = "book.m4b", size = 10000, status = "pending" }
    local header = downloader.build_range_header(file, 0)
    mock.assert_equals(header, nil, "pending → no Range header")
end)

run_test("build_range_header returns Range for partial file with local size", function()
    local file = { filename = "book.m4b", size = 10000, status = "partial" }
    local header = downloader.build_range_header(file, 5000)
    mock.assert_equals(header, "bytes=5000-", "partial → Range from 5000")
end)

run_test("build_range_header returns nil when local size equals expected size", function()
    local file = { filename = "book.m4b", size = 10000, status = "partial" }
    local header = downloader.build_range_header(file, 10000)
    mock.assert_equals(header, nil, "same size → no resume needed")
end)

run_test("build_range_header returns nil when local size exceeds expected", function()
    local file = { filename = "book.m4b", size = 10000, status = "partial" }
    local header = downloader.build_range_header(file, 15000)
    mock.assert_equals(header, nil, "oversize → no resume")
end)

run_test("build_download_request constructs request for pending file", function()
    local file = { filename = "book.m4b", ino = "12345", size = 10000, status = "pending" }
    local req = downloader.build_download_request("li_test", file, "/tmp/out", "mytoken", 0)
    mock.assert_equals(req.url, "http://server/api/items/li_test/file/12345?token=mytoken")
    mock.assert_equals(req.method, "GET")
    assert(req.sink ~= nil, "should have a sink")
    assert(req.headers["Range"] == nil, "no Range for pending")
end)

run_test("build_download_request adds Range header for partial file", function()
    local file = { filename = "book.m4b", ino = "12345", size = 10000, status = "partial" }
    local req = downloader.build_download_request("li_test", file, "/tmp/out", "mytoken", 5000)
    mock.assert_equals(req.headers["Range"], "bytes=5000-", "Range header present")
end)

-- ============================================================
-- Slice 8: Download state & cancel mechanism
-- ============================================================

run_test("create_download_state returns initial state", function()
    local state = downloader.create_download_state()
    mock.assert_equals(state.cancelled, false, "not cancelled initially")
    mock.assert_equals(state.current_file, 0, "no current file")
    mock.assert_equals(state.total_files, 0, "no total files")
    mock.assert_equals(state.bytes_downloaded, 0, "no bytes downloaded")
    mock.assert_equals(state.total_bytes, 0, "no total bytes")
end)

run_test("create_download_state cancels and is_cancelled returns true", function()
    local state = downloader.create_download_state()
    mock.assert_equals(state:is_cancelled(), false, "not cancelled")
    state:cancel()
    mock.assert_equals(state:is_cancelled(), true, "cancelled after cancel()")
end)

run_test("create_download_state tracks progress", function()
    local state = downloader.create_download_state()
    state.total_files = 3
    state.total_bytes = 10000
    state.current_file = 1
    state.bytes_downloaded = 5000
    mock.assert_equals(state:progress_fraction(), 0.5, "50% progress")
end)

run_test("create_download_state progress_fraction handles zero total", function()
    local state = downloader.create_download_state()
    mock.assert_equals(state:progress_fraction(), 0, "zero when no total")
end)

-- ============================================================
-- Slice 9: delete_book
-- ============================================================

run_test("delete_book removes files and manifest entry", function()
    -- Track mock calls
    local removed_id = nil
    local mock_manifest = {
        getBook = function(id)
            if id == "li_test" then
                return {
                    abs_item_id = "li_test",
                    local_dir = "/tmp/test_delete",
                    files = {
                        {filename = "book.m4b", status = "complete"},
                        {filename = "cover.jpg", status = "complete"},
                    },
                }
            end
            return nil
        end,
        removeBook = function(id) removed_id = id end,
    }

    local deleted_files = {}
    local deleted_dirs = {}
    local mock_fs = {
        delete_file = function(path) table.insert(deleted_files, path) end,
        delete_dir = function(path) table.insert(deleted_dirs, path) end,
    }

    local ok = downloader.delete_book("li_test", mock_manifest, mock_fs)
    assert(ok, "delete should succeed")
    mock.assert_equals(removed_id, "li_test", "manifest entry removed")
    mock.assert_equals(#deleted_files, 2, "two files deleted")
    mock.assert_equals(deleted_files[1], "/tmp/test_delete/book.m4b")
    mock.assert_equals(deleted_files[2], "/tmp/test_delete/cover.jpg")
    mock.assert_equals(#deleted_dirs, 1, "directory removed")
    mock.assert_equals(deleted_dirs[1], "/tmp/test_delete")
end)

run_test("delete_book returns false for unknown book", function()
    local mock_manifest = {
        getBook = function() return nil end,
        removeBook = function() end,
    }
    local mock_fs = {
        delete_file = function() end,
        delete_dir = function() end,
    }

    local ok = downloader.delete_book("nonexistent", mock_manifest, mock_fs)
    mock.assert_equals(ok, false, "should fail for unknown book")
end)

run_test("delete_book handles empty files list", function()
    local removed_id = nil
    local mock_manifest = {
        getBook = function()
            return {
                abs_item_id = "li_test",
                local_dir = "/tmp/empty",
                files = {},
            }
        end,
        removeBook = function(id) removed_id = id end,
    }
    local deleted_dirs = {}
    local mock_fs = {
        delete_file = function() end,
        delete_dir = function(path) table.insert(deleted_dirs, path) end,
    }

    local ok = downloader.delete_book("li_test", mock_manifest, mock_fs)
    assert(ok, "should succeed")
    mock.assert_equals(removed_id, "li_test", "manifest entry removed")
    mock.assert_equals(#deleted_dirs, 1, "directory removed even with no files")
end)

-- ============================================================
-- Slice 10: prepare_ebook_download
-- ============================================================

run_test("prepare_ebook_download creates manifest entry for ebook", function()
    local added_entry = nil
    local mock_manifest = {
        getBook = function() return nil end,
        addBook = function(entry) added_entry = entry end,
    }
    local mock_config = {
        get = function(key)
            if key == "download_dir" then return "/tmp/audiobooks" end
            return nil
        end,
    }

    local item = {
        id = "li_ebook1",
        media = {
            metadata = { title = "PDF Book", authorName = "Author" },
            ebooks = {
                { ino = "999", metadata = { filename = "book.pdf", ext = ".pdf", size = 5000 } },
            },
        },
    }

    local ok, result = downloader.prepare_ebook_download(item, mock_manifest, mock_config)
    assert(ok, "should succeed")
    assert(added_entry ~= nil, "should have added manifest entry")
    mock.assert_equals(#added_entry.files, 1)
    mock.assert_equals(added_entry.files[1].filename, "book.pdf")
    mock.assert_equals(added_entry.files[1].type, "ebook")
    mock.assert_equals(added_entry.files[1].status, "pending")
end)

run_test("prepare_ebook_download returns error when no ebooks", function()
    local mock_manifest = {
        getBook = function() return nil end,
        addBook = function() end,
    }
    local mock_config = { get = function() return "/tmp" end }

    local item = {
        id = "li_noebook",
        media = { metadata = { title = "No Ebook" }, ebooks = {} },
    }

    local ok, err = downloader.prepare_ebook_download(item, mock_manifest, mock_config)
    mock.assert_equals(ok, false)
    mock.assert_equals(err, "no_ebook_files")
end)

run_test("get_ebook_files extracts ebooks from item", function()
    local item = {
        media = {
            ebooks = {
                { ino = "111", metadata = { filename = "book.epub", ext = ".epub", size = 1000 } },
                { ino = "222", metadata = { filename = "book.pdf", ext = ".pdf", size = 2000 } },
            },
        },
    }
    local ebooks = downloader.get_ebook_files(item)
    mock.assert_equals(#ebooks, 2, "two ebooks")
    mock.assert_equals(ebooks[1].filename, "book.epub")
    mock.assert_equals(ebooks[2].filename, "book.pdf")
end)

run_test("get_ebook_files returns empty for nil ebooks", function()
    local item = { media = {} }
    local ebooks = downloader.get_ebook_files(item)
    mock.assert_equals(#ebooks, 0)
end)

-- ============================================================
-- Slice 11: reconcile_manifest (startup scan)
-- ============================================================

run_test("reconcile_manifest flags partial when file size mismatch", function()
    local updated = {}
    local mock_manifest = {
        getAllBooks = function()
            return {{
                abs_item_id = "li_test",
                local_dir = "/tmp/test",
                files = {
                    {filename = "book.m4b", size = 10000, status = "complete"},
                },
            }}
        end,
        updateFileStatus = function(id, filename, status)
            table.insert(updated, {id = id, filename = filename, status = status})
        end,
    }
    local mock_fs = {
        get_file_size = function(path)
            -- File is only 5000 bytes, not 10000
            return 5000
        end,
    }

    downloader.reconcile_manifest(mock_manifest, mock_fs)
    mock.assert_equals(#updated, 1, "one file flagged")
    mock.assert_equals(updated[1].status, "partial", "status set to partial")
    mock.assert_equals(updated[1].filename, "book.m4b")
end)

run_test("reconcile_manifest leaves correct files as complete", function()
    local updated = {}
    local mock_manifest = {
        getAllBooks = function()
            return {{
                abs_item_id = "li_test",
                local_dir = "/tmp/test",
                files = {
                    {filename = "book.m4b", size = 10000, status = "complete"},
                },
            }}
        end,
        updateFileStatus = function(_, id, filename, status)
            table.insert(updated, {status = status})
        end,
    }
    local mock_fs = {
        get_file_size = function(path) return 10000 end,
    }

    downloader.reconcile_manifest(mock_manifest, mock_fs)
    mock.assert_equals(#updated, 0, "no files flagged")
end)

run_test("reconcile_manifest flags pending files when file missing", function()
    local updated = {}
    local mock_manifest = {
        getAllBooks = function()
            return {{
                abs_item_id = "li_test",
                local_dir = "/tmp/test",
                files = {
                    {filename = "book.m4b", size = 10000, status = "pending"},
                },
            }}
        end,
        updateFileStatus = function(_, id, filename, status)
            table.insert(updated, {status = status})
        end,
    }
    local mock_fs = {
        get_file_size = function(path) return nil end,  -- file doesn't exist
    }

    downloader.reconcile_manifest(mock_manifest, mock_fs)
    -- Pending files that don't exist stay pending (no update needed)
    mock.assert_equals(#updated, 0, "pending + missing = no change")
end)

run_test("reconcile_manifest handles empty books list", function()
    local mock_manifest = {
        getAllBooks = function() return {} end,
        updateFileStatus = function() end,
    }
    local mock_fs = { get_file_size = function() return 0 end }

    -- Should not crash
    downloader.reconcile_manifest(mock_manifest, mock_fs)
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
