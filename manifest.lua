-- Manifest module for absaudio.koplugin
-- CRUD for per-book state via LuaSettings. Each entry tracks ABS item ID,
-- title, author, local directory, ordered file list with type/size/status,
-- global position (seconds), duration, chapters array, finished flag,
-- last-sync timestamp.
--
-- Public API:
--   manifest.init()                          -- initialize with LuaSettings
--   manifest.addBook(entry)                  -- add a book entry (keyed by abs_item_id)
--   manifest.getBook(abs_item_id)            -- get single book by ID, or nil
--   manifest.getAllBooks()                   -- get all books as array
--   manifest.updateBook(abs_item_id, updates) -- partial update of book fields
--   manifest.removeBook(abs_item_id)         -- delete entry
--   manifest.updateFileStatus(abs_item_id, filename, status) -- update one file's status
--   manifest.updatePosition(abs_item_id, current_time, is_finished) -- update playback position
--   manifest.getRecentBook()                 -- get most recently played book (for dashboard)

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")

local manifest = {}

-- Internal state
local settings = nil

--- Build the manifest file path
local function manifest_path()
    return DataStorage:getSettingsDir() .. "/absaudio_manifest.lua"
end

--- Get the books table from settings (creates if missing)
local function get_books()
    local books = settings:readSetting("books")
    if books == nil then
        books = {}
        settings:saveSetting("books", books)
    end
    return books
end

--- Initialize manifest store (idempotent)
--- Only opens a new LuaSettings on the first call; subsequent calls are no-ops
--- so that in-memory mutations (addBook, updateFileStatus, etc.) are preserved.
function manifest.init()
    if settings then return end
    settings = LuaSettings:open(manifest_path())
    -- Ensure books table exists
    get_books()
end

--- Persist current manifest state to disk.
--- Call after any mutation that should survive across sessions.
function manifest.flush()
    if settings then
        settings:flush()
    end
end

--- Add a book entry, keyed by abs_item_id
-- @param entry table  must contain abs_item_id, plus any manifest fields
function manifest.addBook(entry)
    local books = get_books()
    books[entry.abs_item_id] = entry
    settings:saveSetting("books", books)
    settings:flush()
end

--- Get a single book by ABS item ID
-- @param abs_item_id string
-- @return table|nil  book entry or nil if not found
function manifest.getBook(abs_item_id)
    local books = get_books()
    return books[abs_item_id]
end

--- Get all books as an array
-- @return table  array of book entries
function manifest.getAllBooks()
    local books = get_books()
    local result = {}
    for _, entry in pairs(books) do
        table.insert(result, entry)
    end
    return result
end

--- Partially update a book's fields
-- @param abs_item_id string
-- @param updates table  fields to update (merged into existing entry)
function manifest.updateBook(abs_item_id, updates)
    local books = get_books()
    local entry = books[abs_item_id]
    if entry then
        for key, value in pairs(updates) do
            entry[key] = value
        end
        settings:saveSetting("books", books)
        settings:flush()
    end
end

--- Remove a book entry by ABS item ID
-- @param abs_item_id string
function manifest.removeBook(abs_item_id)
    local books = get_books()
    books[abs_item_id] = nil
    settings:saveSetting("books", books)
    settings:flush()
end

--- Update the download status of a specific file within a book
-- @param abs_item_id string
-- @param filename string  the file to update
-- @param status string  "complete", "partial", or "pending"
function manifest.updateFileStatus(abs_item_id, filename, status)
    local books = get_books()
    local entry = books[abs_item_id]
    if entry and entry.files then
        for _, file in ipairs(entry.files) do
            if file.filename == filename then
                file.status = status
                break
            end
        end
        settings:saveSetting("books", books)
        settings:flush()
    end
end

--- Update playback position for a book
-- @param abs_item_id string
-- @param current_time number  position in seconds
-- @param is_finished boolean
function manifest.updatePosition(abs_item_id, current_time, is_finished)
    local books = get_books()
    local entry = books[abs_item_id]
    if entry then
        entry.current_time = current_time
        entry.is_finished = is_finished
        settings:saveSetting("books", books)
        settings:flush()
    end
end

--- Get the most recently played book (for dashboard Resume)
-- Returns the book with the highest current_time that isn't finished,
-- or the last updated book if all are finished.
-- @return table|nil
function manifest.getRecentBook()
    local books = manifest.getAllBooks()
    if #books == 0 then return nil end

    local recent = nil
    local best_time = -1
    for _, book in ipairs(books) do
        if book.current_time and book.current_time > best_time then
            best_time = book.current_time
            recent = book
        end
    end
    return recent
end

--- Reset the in-memory settings handle (for testing)
--- Allows init() to re-open from disk on next call
function manifest._resetSettings()
    settings = nil
end

--- Check if a book is fully downloaded (all files complete)
-- @param abs_item_id string
-- @return boolean
function manifest.isDownloaded(abs_item_id)
    local entry = manifest.getBook(abs_item_id)
    if not entry or not entry.files or #entry.files == 0 then
        return false
    end
    for _, file in ipairs(entry.files) do
        if file.status ~= "complete" then
            return false
        end
    end
    return true
end

--- Check if a book has any incomplete files (pending or partial)
-- @param abs_item_id string
-- @return boolean
function manifest.hasIncompleteFiles(abs_item_id)
    local entry = manifest.getBook(abs_item_id)
    if not entry or not entry.files then return false end
    for _, file in ipairs(entry.files) do
        if file.status == "pending" or file.status == "partial" then
            return true
        end
    end
    return false
end

--- Get only the incomplete files for a book
-- @param abs_item_id string
-- @return table  array of file entries with pending/partial status
function manifest.getIncompleteFiles(abs_item_id)
    local entry = manifest.getBook(abs_item_id)
    if not entry or not entry.files then return {} end
    local result = {}
    for _, file in ipairs(entry.files) do
        if file.status == "pending" or file.status == "partial" then
            table.insert(result, file)
        end
    end
    return result
end

--- Get total size of all files for a book
-- @param abs_item_id string
-- @return number  total bytes
function manifest.getTotalFileSize(abs_item_id)
    local entry = manifest.getBook(abs_item_id)
    if not entry or not entry.files then return 0 end
    local total = 0
    for _, file in ipairs(entry.files) do
        total = total + (file.size or 0)
    end
    return total
end

--- Get total size of completed files for a book
-- @param abs_item_id string
-- @return number  bytes already downloaded
function manifest.getDownloadedSize(abs_item_id)
    local entry = manifest.getBook(abs_item_id)
    if not entry or not entry.files then return 0 end
    local total = 0
    for _, file in ipairs(entry.files) do
        if file.status == "complete" then
            total = total + (file.size or 0)
        end
    end
    return total
end

return manifest
