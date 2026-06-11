-- Download orchestrator for absaudio.koplugin
-- Handles filename sanitization, format preference filtering, file selection,
-- and download orchestration (with coroutine-based chunked downloading).
--
-- Public API:
--   downloader.sanitize_filename(filename)  -- clean filename for local filesystem
-- Return convention: mixed — sanitize_filename returns direct value;
--   execute/prepare return (boolean, error_string) on failure.
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
    -- Get audio files from expanded item
    local audio_files = {}
    if item.media and type(item.media.audioFiles) == "table" then
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

    -- Check for existing manifest entry
    local existing = manifest.getBook(item.id)

    -- If no audio files in item data, check if already fully downloaded
    -- (handles the case where the item doesn't carry audioFiles)
    if #audio_files == 0 then
        if existing and manifest.isDownloaded(item.id) then
            return false, "already_downloaded"
        end
        return false, "no_audio_files"
    end

    -- Filter by preferred format
    local preferred = config.get("preferred_format") or "m4b"
    local filtered = downloader.filter_audio_files(audio_files, preferred)

    if existing then
        -- Check if all AUDIO files are already complete
        -- (files without 'type' field default to 'audio' for backward compat)
        local all_audio_complete = false
        if existing.files then
            all_audio_complete = true
            local has_audio = false
            for _, f in ipairs(existing.files) do
                local is_audio = (f.type == nil or f.type == "audio")
                if is_audio then
                    has_audio = true
                    if f.status ~= "complete" then
                        all_audio_complete = false
                        break
                    end
                end
            end
            if not has_audio then all_audio_complete = false end
        end
        if all_audio_complete then
            return false, "already_downloaded"
        end

        -- Merge audio files into existing entry
        for _, f in ipairs(filtered) do
            local sanitized = downloader.sanitize_filename(f.filename)
            local already_tracked = false
            if existing.files then
                for _, ef in ipairs(existing.files) do
                    if ef.ino == f.ino then
                        already_tracked = true
                        break
                    end
                end
            end
            if not already_tracked then
                if not existing.files then existing.files = {} end
                table.insert(existing.files, {
                    filename = sanitized,
                    ino = f.ino,
                    size = f.size,
                    type = "audio",
                    status = "pending",
                })
            end
        end
        manifest.addBook(existing)  -- persist merged entry
        return true, existing
    end

    -- No existing entry — create fresh audio manifest entry
    local title = (item.media and item.media.metadata and item.media.metadata.title) or "Unknown Title"
    local author = (item.media and item.media.metadata and item.media.metadata.authorName) or "Unknown Author"
    local download_dir = config.get("download_dir") or "/tmp/audiobooks"
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
    if not item or not item.media then return {} end
    local result = {}
    -- ABS returns media.ebookFile (singular object), not media.ebooks (array)
    if type(item.media.ebookFile) == "table" then
        local ef = item.media.ebookFile
        local meta = ef.metadata or {}
        table.insert(result, {
            ino = ef.ino,
            filename = meta.filename or "unknown",
            ext = meta.ext or "",
            size = meta.size or 0,
        })
    elseif item.media.ebooks then
        for _, ef in ipairs(item.media.ebooks) do
            local meta = ef.metadata or {}
            table.insert(result, {
                ino = ef.ino,
                filename = meta.filename or "unknown",
                ext = meta.ext or "",
                size = meta.size or 0,
            })
        end
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

    -- Check for existing manifest entry (audio already downloaded)
    local existing = manifest.getBook(item.id)
    if existing then
        -- Merge ebook files into existing entry
        for _, f in ipairs(ebook_files) do
            local sanitized = downloader.sanitize_filename(f.filename)
            -- Skip if this ebook file already tracked
            local already_tracked = false
            if existing.files then
                for _, ef in ipairs(existing.files) do
                    if ef.ino == f.ino then
                        already_tracked = true
                        break
                    end
                end
            end
            if not already_tracked then
                if not existing.files then existing.files = {} end
                table.insert(existing.files, {
                    filename = sanitized,
                    ino = f.ino,
                    size = f.size,
                    type = "ebook",
                    status = "pending",
                })
            end
        end
        manifest.addBook(existing)  -- persist merged entry
        return true, existing
    end

    -- No existing entry — create fresh ebook-only manifest entry
    local title = (item.media and item.media.metadata and item.media.metadata.title) or "Unknown Title"
    local author = (item.media and item.media.metadata and item.media.metadata.authorName) or "Unknown Author"
    local download_dir = config.get("download_dir") or "/tmp/audiobooks"
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
                    local actual_size = fs.get_file_size(path)
                    -- If file doesn't exist or size doesn't match, mark as partial
                    if actual_size == nil or actual_size ~= file.size then
                        manifest.updateFileStatus(book.abs_item_id, file.filename, "partial")
                    end
                end
            end
        end
    end
end

------------------------------------------------------------------------
-- Download one file: mkdir, open, sink, API call, close, status update.
-- @param entry  { abs_item_id, local_dir }
-- @param file   { filename, ino, size, status }
-- @param deps   { manifest, api, fs, state }
-- @return ok, reason
------------------------------------------------------------------------
function downloader._download_one_file(entry, file, deps)
    deps.fs.mkdir(entry.local_dir)

    local open_mode = "wb"
    local extra_headers = nil
    local local_size = deps.fs.get_file_size(entry.local_dir .. "/" .. file.filename) or 0

    if file.status == "partial" and local_size > 0 and local_size < file.size then
        open_mode = "ab"
        extra_headers = { ["Range"] = "bytes=" .. tostring(local_size) .. "-" }
    end

    local file_handle = deps.fs.open(entry.local_dir .. "/" .. file.filename, open_mode)
    if not file_handle then
        deps.manifest.updateFileStatus(entry.abs_item_id, file.filename, "partial")
        return false, "file_open_error"
    end

    local sink = function(chunk)
        if chunk then
            file_handle:write(chunk)
            deps.state.bytes_downloaded = deps.state.bytes_downloaded + #chunk
        end
        return true
    end

    local ok, result = deps.api.downloadFile(entry.abs_item_id, file.ino, sink, extra_headers)
    file_handle:close()

    if ok then
        deps.manifest.updateFileStatus(entry.abs_item_id, file.filename, "complete")
    else
        deps.manifest.updateFileStatus(entry.abs_item_id, file.filename, "partial")
        return false, "download_failed"
    end

    return true, nil
end
------------------------------------------------------------------------
-- Download all pending/partial files in a manifest entry.
-- @param entry  manifest book entry with .files array
-- @param deps    { manifest, api, fs, state, on_progress }
-- @return ok, reason
------------------------------------------------------------------------
function downloader.execute_download(entry, deps)
    local files_to_download = downloader.select_files_to_download(entry.files)
    local state = deps.state
    state.total_files = #files_to_download
    state.total_bytes = downloader.calculate_download_size(entry.files)

    for i, file in ipairs(files_to_download) do
        if state:is_cancelled() then
            return false, "cancelled"
        end

        state.current_file = i

        local ok, reason = downloader._download_one_file(entry, file, deps)
        if not ok then return ok, reason end

        if deps.on_progress then
            deps.on_progress(state)
        end
    end

    return true, nil
end

------------------------------------------------------------------------
-- Execute download of a single file (for per-file scheduling in UI).
-- Delegates to _download_one_file.
-- @param entry table  manifest book entry
-- @param file table   single file entry to download
-- @param deps table   { manifest, api, fs, state }
-- @return boolean ok
-- @return string|nil  reason on failure
------------------------------------------------------------------------
function downloader.execute_single_file_download(entry, file, deps)
    return downloader._download_one_file(entry, file, deps)
end

------------------------------------------------------------------------
-- Get free disk space for a path (uses df command)
-- Returns nil if unable to determine
-- @param path string  filesystem path
-- @return number|nil  free bytes
------------------------------------------------------------------------
function downloader.get_free_space(path)
    -- Escape single quotes for safe shell interpolation
    local safe_path = path:gsub("'", "'\\\"'" )
    local handle = io.popen("df -k '" .. safe_path .. "' 2>/dev/null | tail -1 | awk '{print $4}'")
    if handle then
        local result = handle:read("*n")
        handle:close()
        if result then
            return result * 1024  -- convert KB to bytes
        end
    end
    return nil
end

-- format_bytes is now in widget_helpers; re-export for backward compat
local widget_helpers = require("absaudio/widget_helpers")
downloader.format_bytes = widget_helpers.format_bytes

------------------------------------------------------------------------
-- Start a chunked (coroutine-based) download of a single file.
-- Returns pumpable handle: .pump(), .cancel(), .finalize(), .is_done()
------------------------------------------------------------------------
function downloader.start_chunked_download(entry, file, deps)
    deps.fs.mkdir(entry.local_dir)

    local open_mode = "wb"
    local extra_headers = nil
    local local_size = deps.fs.get_file_size(entry.local_dir .. "/" .. file.filename) or 0

    abs_logger.info(string.format(
        "start_chunked_download: file=%s status=%s local_size=%d expected_size=%d",
        file.filename, tostring(file.status), local_size, file.size or 0))
    if file.status == "partial" and local_size > 0 and local_size < file.size then
        open_mode = "ab"
        extra_headers = { ["Range"] = "bytes=" .. tostring(local_size) .. "-" }
        abs_logger.info("Resume: open_mode=" .. open_mode .. " Range=" .. tostring(extra_headers["Range"]))
    end

    local file_handle = deps.fs.open(entry.local_dir .. "/" .. file.filename, open_mode)
    if not file_handle then
        deps.manifest.updateFileStatus(entry.abs_item_id, file.filename, "partial")
        return nil, "file_open_error"
    end

    local cancelled = false
    local done = false
    local download_ok = false

    -- Build the download URL
    local download_url = deps.api.getDownloadUrl(entry.abs_item_id, file.ino)

    -- Get the chunked_http module (injected or required)
    local chunked_http = deps.chunked_http or require("absaudio.chunked_http")

    -- Coroutine: performs raw socket download, yields between chunks
    local co = coroutine.create(function()
        local ok, result = chunked_http.download(
            download_url,
            extra_headers,
            function(chunk)
                file_handle:write(chunk)
                deps.state.bytes_downloaded = deps.state.bytes_downloaded + #chunk
            end
        )
        download_ok = ok
        done = true
        return ok, result
    end)

    local handle = {
        _co = co,
        _file_handle = file_handle,
        _entry = entry,
        _file = file,
        _deps = deps,

        --- Resume the download coroutine. Returns true if still running.
        pump = function(self)
            if done or cancelled then return false end
            local ok, msg = coroutine.resume(self._co)
            if not ok then
                download_ok = false
                done = true
                return false
            end
            return not done
        end,

        --- Mark the download as cancelled.
        cancel = function(self)
            cancelled = true
        end,

        --- True when the download coroutine has finished.
        is_done = function(self)
            return done or cancelled
        end,

        --- Close the file handle and update manifest. Returns ok, reason.
        finalize = function(self)
            if self._file_handle then
                self._file_handle:close()
                self._file_handle = nil
            end
            if download_ok and not cancelled then
                self._deps.manifest.updateFileStatus(
                    self._entry.abs_item_id, self._file.filename, "complete")
                return true, nil
            else
                self._deps.manifest.updateFileStatus(
                    self._entry.abs_item_id, self._file.filename, "partial")
                return false, cancelled and "cancelled" or "download_failed"
            end
        end,
    }

    return handle
end

return downloader
