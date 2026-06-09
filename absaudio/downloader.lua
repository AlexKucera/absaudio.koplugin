-- Download orchestrator for absaudio.koplugin
-- Handles filename sanitization, format preference filtering, file selection,
-- and download orchestration (with coroutine-based chunked downloading).
--
-- Public API:
--   downloader.sanitize_filename(filename)  -- clean filename for local filesystem
--
local abs_logger = require("abs_logger")

local downloader = {}

------------------------------------------------------------------------
-- Sanitize a filename for safe local filesystem use
-- Replaces characters illegal on FAT32/ext4/APFS with underscores,
-- strips leading/trailing spaces and dots, returns "untitled" if empty.
-- @param filename string  raw filename from ABS
-- @return string  sanitized filename
------------------------------------------------------------------------
function downloader.sanitize_filename(filename)
    if not filename or filename == "" then
        return "untitled"
    end

    -- Replace illegal characters with underscores
    local safe = filename:gsub('[:<>|"*?\\/%c]', "_")

    -- Strip leading/trailing spaces and dots
    safe = safe:gsub("^[%s.]+", "")
    safe = safe:gsub("[%s.]+$", "")

    -- If result is empty or only underscores, return untitled
    if safe == "" or safe:match("^_+$") then
        return "untitled"
    end

    return safe
end

------------------------------------------------------------------------
-- Filter audio files by preferred format with fallback chain
-- Preferred → mp3 → all audio files
-- @param files table  array of file entries with at least {ext, filename}
-- @param preferred_format string  e.g. "m4b" or "mp3"
-- @return table  filtered array of file entries
------------------------------------------------------------------------
function downloader.filter_audio_files(files, preferred_format)
    if not files or #files == 0 then return {} end

    local preferred_ext = "." .. (preferred_format or "m4b")
    local fallback_ext = ".mp3"

    -- Try preferred format first
    local preferred = {}
    for _, f in ipairs(files) do
        if f.ext == preferred_ext then
            table.insert(preferred, f)
        end
    end
    if #preferred > 0 then return preferred end

    -- Fallback to mp3
    local mp3 = {}
    for _, f in ipairs(files) do
        if f.ext == fallback_ext then
            table.insert(mp3, f)
        end
    end
    if #mp3 > 0 then return mp3 end

    -- Final fallback: all files
    local all = {}
    for _, f in ipairs(files) do
        table.insert(all, f)
    end
    return all
end

------------------------------------------------------------------------
-- Select files that need downloading (skip complete, include partial)
-- @param files table|nil  array of file entries with {status}
-- @return table  files with status "pending" or "partial"
------------------------------------------------------------------------
function downloader.select_files_to_download(files)
    if not files then return {} end
    local result = {}
    for _, f in ipairs(files) do
        if f.status == "pending" or f.status == "partial" then
            table.insert(result, f)
        end
    end
    return result
end

------------------------------------------------------------------------
-- Calculate total bytes needed to download (pending + partial files)
-- @param files table|nil  array of file entries with {size, status}
-- @return number  total bytes needed
------------------------------------------------------------------------
function downloader.calculate_download_size(files)
    if not files then return 0 end
    local total = 0
    for _, f in ipairs(files) do
        if f.status == "pending" or f.status == "partial" then
            total = total + (f.size or 0)
        end
    end
    return total
end

------------------------------------------------------------------------
-- Check if there is enough free space for a download
-- @param needed_bytes number  total bytes to download
-- @param available_bytes number  free space on disk
-- @return boolean  true if enough space (or 0 bytes needed)
------------------------------------------------------------------------
function downloader.check_free_space(needed_bytes, available_bytes)
    if needed_bytes == 0 then return true end
    return available_bytes >= needed_bytes
end

------------------------------------------------------------------------
-- Prepare a download: validate, filter audio files, create manifest entry
-- @param item table  ABS item with id and media (audioFiles, metadata, chapters, duration)
-- @param manifest table  manifest module with getBook, addBook, isDownloaded
-- @param config table  config module with get(key)
-- @return boolean ok
-- @return string|table  result (manifest entry on success, error string on failure)
------------------------------------------------------------------------
function downloader.prepare_download(item, manifest, config)
    -- Check if already downloaded
    if manifest.isDownloaded(item.id) then
        return false, "already_downloaded"
    end

    -- Get audio files from expanded item
    local audio_files = {}
    if item.media and item.media.audioFiles then
        for _, af in ipairs(item.media.audioFiles) do
            local meta = af.metadata or {}
            table.insert(audio_files, {
                ino = af.ino,
                filename = meta.filename or "unknown",
                ext = meta.ext or "",
                size = meta.size or 0,
                duration = af.duration or 0,
            })
        end
    end

    if #audio_files == 0 then
        return false, "no_audio_files"
    end

    -- Filter by preferred format
    local preferred = config:get("preferred_format") or "m4b"
    local filtered = downloader.filter_audio_files(audio_files, preferred)

    -- Build manifest entry
    local title = (item.media and item.media.metadata and item.media.metadata.title) or "Unknown Title"
    local author = (item.media and item.media.metadata and item.media.metadata.authorName) or "Unknown Author"
    local download_dir = config:get("download_dir") or "/tmp/audiobooks"
    local dir_name = downloader.sanitize_filename(author .. "_" .. title)
    local local_dir = download_dir .. "/" .. dir_name

    local manifest_files = {}
    for _, f in ipairs(filtered) do
        table.insert(manifest_files, {
            filename = downloader.sanitize_filename(f.filename),
            ino = f.ino,
            size = f.size,
            type = "audio",
            status = "pending",
        })
    end

    local entry = {
        abs_item_id = item.id,
        title = title,
        author = author,
        local_dir = local_dir,
        files = manifest_files,
        current_time = 0,
        duration = (item.media and item.media.duration) or 0,
        chapters = (item.media and item.media.chapters) or {},
        is_finished = false,
        last_synced_at = os.time(),
    }

    manifest.addBook(entry)
    return true, entry
end

------------------------------------------------------------------------
-- Build Range header for resuming partial downloads
-- @param file table  file entry with {size, status}
-- @param local_size number  bytes already on disk
-- @return string|nil  Range header value (e.g. "bytes=5000-") or nil
------------------------------------------------------------------------
function downloader.build_range_header(file, local_size)
    if file.status ~= "partial" then return nil end
    if local_size <= 0 then return nil end
    if local_size >= file.size then return nil end
    return "bytes=" .. tostring(local_size) .. "-"
end

------------------------------------------------------------------------
-- Build a download request table for a file
-- @param item_id string  ABS item ID
-- @param file table  file entry with {ino, filename, size, status}
-- @param local_path string  directory to save to
-- @param token string  ABS API token
-- @param local_size number  bytes already on disk (for resume)
-- @param server_url string|nil  ABS server URL (default: requires api module)
-- @return table  request table with url, method, headers, sink
------------------------------------------------------------------------
function downloader.build_download_request(item_id, file, local_path, token, local_size, server_url)
    server_url = server_url or "http://server"
    local url = server_url .. "/api/items/" .. item_id .. "/file/" .. file.ino .. "?token=" .. token

    local headers = {
        ["Accept"] = "*/*",
    }

    local range = downloader.build_range_header(file, local_size)
    if range then
        headers["Range"] = range
    end

    -- Simple sink that collects chunks (will be replaced by coroutine sink in production)
    local chunks = {}
    local sink = function(chunk)
        if chunk then table.insert(chunks, chunk) end
    end

    return {
        url = url,
        method = "GET",
        headers = headers,
        sink = sink,
        _chunks = chunks,  -- for testing
    }
end

------------------------------------------------------------------------
-- Create a download state object for tracking progress and cancellation
-- @return table  state object with cancelled, current_file, total_files,
--                bytes_downloaded, total_bytes, cancel(), is_cancelled(), progress_fraction()
------------------------------------------------------------------------
function downloader.create_download_state()
    local state = {
        cancelled = false,
        current_file = 0,
        total_files = 0,
        bytes_downloaded = 0,
        total_bytes = 0,
    }

    function state:cancel()
        self.cancelled = true
    end

    function state:is_cancelled()
        return self.cancelled
    end

    function state:progress_fraction()
        if self.total_bytes == 0 then return 0 end
        return self.bytes_downloaded / self.total_bytes
    end

    return state
end

------------------------------------------------------------------------
-- Delete a downloaded book: remove all files, directory, and manifest entry
-- @param abs_item_id string  book ID
-- @param manifest table  manifest module with getBook, removeBook
-- @param fs table  filesystem adapter with delete_file(path), delete_dir(path)
-- @return boolean  true if book found and deleted
------------------------------------------------------------------------
function downloader.delete_book(abs_item_id, manifest, fs)
    local entry = manifest.getBook(abs_item_id)
    if not entry then return false end

    -- Delete all files in the book's local directory
    if entry.files then
        for _, file in ipairs(entry.files) do
            fs.delete_file(entry.local_dir .. "/" .. file.filename)
        end
    end

    -- Remove the directory itself
    if entry.local_dir then
        fs.delete_dir(entry.local_dir)
    end

    -- Remove manifest entry
    manifest.removeBook(abs_item_id)
    return true
end

------------------------------------------------------------------------
-- Extract ebook files from an ABS item
-- @param item table  ABS item with media.ebooks
-- @return table  array of ebook file entries
------------------------------------------------------------------------
function downloader.get_ebook_files(item)
    if not item or not item.media or not item.media.ebooks then return {} end
    local result = {}
    for _, ef in ipairs(item.media.ebooks) do
        local meta = ef.metadata or {}
        table.insert(result, {
            ino = ef.ino,
            filename = meta.filename or "unknown",
            ext = meta.ext or "",
            size = meta.size or 0,
        })
    end
    return result
end

------------------------------------------------------------------------
-- Prepare an ebook download: create manifest entry for ebook file(s)
-- @param item table  ABS item with id and media.ebooks
-- @param manifest table  manifest module
-- @param config table  config module
-- @return boolean ok
-- @return string|table  result or error string
------------------------------------------------------------------------
function downloader.prepare_ebook_download(item, manifest, config)
    local ebook_files = downloader.get_ebook_files(item)
    if #ebook_files == 0 then
        return false, "no_ebook_files"
    end

    local title = (item.media and item.media.metadata and item.media.metadata.title) or "Unknown Title"
    local author = (item.media and item.media.metadata and item.media.metadata.authorName) or "Unknown Author"
    local download_dir = config:get("download_dir") or "/tmp/audiobooks"
    local dir_name = downloader.sanitize_filename(author .. "_" .. title)
    local local_dir = download_dir .. "/" .. dir_name

    local manifest_files = {}
    for _, f in ipairs(ebook_files) do
        table.insert(manifest_files, {
            filename = downloader.sanitize_filename(f.filename),
            ino = f.ino,
            size = f.size,
            type = "ebook",
            status = "pending",
        })
    end

    local entry = {
        abs_item_id = item.id,
        title = title,
        author = author,
        local_dir = local_dir,
        files = manifest_files,
        current_time = 0,
        duration = 0,
        chapters = {},
        is_finished = false,
        last_synced_at = os.time(),
    }

    manifest.addBook(entry)
    return true, entry
end

------------------------------------------------------------------------
-- Reconcile manifest against actual files on disk (startup scan)
-- Flags complete files whose actual size doesn't match expected size as "partial"
-- @param manifest table  manifest module with getAllBooks, updateFileStatus
-- @param fs table  filesystem adapter with get_file_size(path) → number|nil
------------------------------------------------------------------------
function downloader.reconcile_manifest(manifest, fs)
    local books = manifest.getAllBooks()
    if not books then return end

    for _, book in ipairs(books) do
        if book.files and book.local_dir then
            for _, file in ipairs(book.files) do
                if file.status == "complete" then
                    local path = book.local_dir .. "/" .. file.filename
                    local actual_size = fs:get_file_size(path)
                    -- If file doesn't exist or size doesn't match, mark as partial
                    if actual_size == nil or actual_size ~= file.size then
                        manifest.updateFileStatus(book.abs_item_id, file.filename, "partial")
                    end
                end
            end
        end
    end
end

return downloader
