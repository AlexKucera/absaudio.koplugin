-- Inkview playback backend for absaudio.koplugin
-- Wraps PocketBook's inkview audio API via LuaJIT FFI.
-- Only works on PocketBook devices with inkview library.
--
-- Public API (same interface as StubBackend):
--   inkview_backend.new(opts) → backend instance
--     play(), pause(), resume(), stop(), close()
--     getPosition(), setPosition(sec), getDuration()
--     getCurrentTrack(), getPlaybackSpeed(), setPlaybackSpeed(speed)
--     isFinished()
--
-- FFI bindings:
--   LoadPlaylist(path)    — load m3u/playlist file
--   PlayFile(path)        — play single file (fallback)
--   Play() / Stop() / Pause() / Resume()
--   GetPositionSeconds()  — current playback position
--   SetPositionSeconds(s) — seek to position
--   GetPlaybackSpeed() / SetPlaybackSpeed(multiplier)
--   GetTimeLength()       — total duration of current track

local abs_logger = require("abs_logger")

local inkview_backend = {}

-- FFI definitions (lazy-loaded, only on PocketBook)
local ffi_loaded = false
local ffi = nil
local inkview_ffi = nil

local function try_load_ffi()
    if ffi_loaded then return true end
    local ok, result = pcall(require, "ffi")
    if not ok then return false end
    ffi = result

    -- Try to load inkview shared library
    local lib_ok, lib_err = pcall(function()
        inkview_ffi = ffi.load("inkview")
        -- Define FFI function signatures
        ffi.cdef[[
            typedef int InkViewAPI;

            // Audio playback
            int LoadPlaylist(const char* path);
            int PlayFile(const char* path);
            void Play(void);
            void Stop(void);
            void Pause(void);
            void Resume(void);

            // Position & duration (in seconds)
            int GetPositionSeconds(void);
            void SetPositionSeconds(int seconds);
            int GetTimeLength(void);

            // Speed control
            double GetPlaybackSpeed(void);
            void SetPlaybackSpeed(double speed);

            // State queries
            int IsPlaying(void);
            int IsPaused(void);
        ]]
    end)

    if not lib_ok then
        abs_logger.warn("inkview_backend: FFI library not available (" .. tostring(lib_err) .. ")")
        return false
    end

    ffi_loaded = true
    return true
end

function inkview_backend.new(opts)
    opts = opts or {}
    local track_durations = opts.track_durations or {}
    local file_paths = opts.file_paths or {}
    local start_position = opts.start_position or 0
    local playback_speed = opts.playback_speed or 1.0
    local on_finished = opts.on_finished

    -- Calculate total duration
    local total_duration = 0
    for _, d in ipairs(track_durations) do
        total_duration = total_duration + d
    end

    -- State (mirrors stub for consistency)
    local state = "stopped"
    local finished = false

    -- Track which file/track we're on (for multi-file books)
    local current_file_index = 0

    local self = {}

    function self:getState() return state end

    function self:getDuration()
        return total_duration
    end

    function self:isFinished() return finished end

    function self:getPlaybackSpeed() return playback_speed end

    function self:setPlaybackSpeed(speed)
        playback_speed = speed or 1.0
        if ffi_loaded and inkview_ffi then
            pcall(function() inkview_ffi.SetPlaybackSpeed(playback_speed) end)
        end
    end

    function self:play()
        if state == "playing" then return end

        if not try_load_ffi() then
            abs_logger.warn("inkview_backend: cannot play — FFI not available")
            state = "stopped"
            return
        end

        -- Try LoadPlaylist for multi-file, fallback to PlayFile for single
        local ok, err = pcall(function()
            if #file_paths > 1 then
                -- Build m3u playlist and load it
                local playlist_path = self:_buildPlaylist()
                if playlist_path then
                    local result = inkview_ffi.LoadPlaylist(playlist_path)
                    if result ~= 0 then
                        -- Fallback: try first file
                        inkview_ffi.PlayFile(file_paths[1])
                    end
                end
            elseif #file_paths == 1 then
                inkview_ffi.PlayFile(file_paths[1])
            end

            -- Seek to start position if needed
            if start_position and start_position > 0 then
                inkview_ffi.SetPositionSeconds(math.floor(start_position))
            end

            -- Start playback
            inkview_ffi.Play()
        end)

        if not ok then
            abs_logger.warn("inkview_backend: play failed — " .. tostring(err))
            state = "stopped"
            return
        end

        state = "playing"

        -- If starting from a specific position (not beginning), seek there
        if start_position and start_position > 0 then
            pcall(function()
                inkview_ffi.SetPositionSeconds(math.floor(start_position))
            end)
        end
    end

    function self:pause()
        if state ~= "playing" then return end
        if ffi_loaded and inkview_ffi then
            pcall(function() inkview_ffi.Pause() end)
        end
        state = "paused"
    end

    function self:resume()
        if state ~= "paused" then return end
        if ffi_loaded and inkview_ffi then
            pcall(function() inkview_ffi.Resume() end)
        end
        state = "playing"
    end

    function self:stop()
        if ffi_loaded and inkview_ffi then
            pcall(function() inkview_ffi.Stop() end)
        end
        state = "stopped"
        current_file_index = 0
    end

    function self:setPosition(global_seconds)
        if ffi_loaded and inkview_ffi then
            pcall(function()
                inkview_ffi.SetPositionSeconds(math.floor(global_seconds))
            end)
        end
        -- Note: position is managed by inkview; we don't track it locally
    end

    function self:getPosition()
        if not ffi_loaded or not inkview_ffi then
            return start_position or 0
        end
        local ok, pos = pcall(function()
            return inkview_ffi.GetPositionSeconds()
        end)
        return ok and pos or (start_position or 0)
    end

    function self:getCurrentTrack()
        if state == "stopped" then return 0 end
        -- Estimate current track from position
        local pos = self:getPosition()
        local player_mod = require("absaudio/player")
        local t, _ = player_mod.global_to_track_offset(pos, track_durations)
        return t
    end

    function self:close()
        self:stop()
        finished = false
        state = "stopped"
    end

    -- Build an m3u playlist file from file_paths
    function self:_buildPlaylist()
        if #file_paths == 0 then return nil end

        -- Use first file's directory as base for playlist
        local base_dir = file_paths[1]:match("^(.-)[^/]+$") or "/tmp"
        local playlist_path = base_dir .. "/playlist.m3u"

        local f, err = io.open(playlist_path, "w")
        if not f then
            abs_logger.warn("inkview_backend: cannot create playlist — " .. tostring(err))
            return nil
        end

        f.write(f, "#EXTM3U\n")
        for _, path in ipairs(file_paths) do
            f.write(f, path .. "\n")
        end
        f:close()

        return playlist_path
    end

    return self
end

-- Export whether FFI is available (useful for feature detection)
function inkview_backend.is_available()
    return try_load_ffi()
end

return inkview_backend
