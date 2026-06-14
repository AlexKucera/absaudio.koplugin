-- Player module for absaudio.koplugin
-- Wraps PocketBook inkview audio API via LuaJIT FFI with a strategy pattern:
--   InkviewBackend (real FFI, device only) / StubBackend (emulator + tests)
--
-- Public API (pure math — no backend needed):
--   player.global_to_track_offset(global_seconds, track_durations) → (track_index, offset)
--   player.track_offset_to_global(track_index, offset, track_durations) → global_seconds
--
-- Public API (requires backend):
--   player.create(opts) → player_instance
--     play(), pause(), resume(), stop(), close()
--     getPosition(), setPosition(global_seconds), getDuration()
--     getCurrentTrack(), getPlaybackSpeed(), setPlaybackSpeed(multiplier)

local abs_logger = require("abs_logger")

-- Backend implementations (lazy-loaded)
local stub_backend_mod = nil
local inkview_backend_mod = nil

local function get_stub_backend()
    if not stub_backend_mod then
        stub_backend_mod = require("absaudio/stub_backend")
    end
    return stub_backend_mod
end
local function get_inkview_backend()
    if not inkview_backend_mod then
        inkview_backend_mod = require("absaudio/inkview_backend")
    end
    return inkview_backend_mod
end

local ffmpeg_backend_mod = nil
local function get_ffmpeg_backend()
    if not ffmpeg_backend_mod then
        ffmpeg_backend_mod = require("absaudio/ffmpeg_backend")
    end
    return ffmpeg_backend_mod
end

local player = {}

------------------------------------------------------------------------
-- Pure math: convert global position (seconds) to (track index, offset)
--
-- @param global_seconds  number  position from start of book in seconds
-- @param track_durations  array   duration of each track in seconds
-- @return number track_index  1-based index (0 if no tracks)
-- @return number offset       seconds into the identified track
------------------------------------------------------------------------
function player.global_to_track_offset(global_seconds, track_durations)
    if not track_durations or #track_durations == 0 then
        return 0, 0
    end

    -- Clamp negative positions to start
    local pos = global_seconds
    if pos < 0 then
        pos = 0
    end

    -- Walk through tracks to find which one contains this position
    local accumulated = 0
    for i, duration in ipairs(track_durations) do
        if pos < accumulated + duration then
            return i, pos - accumulated
        end
        accumulated = accumulated + duration
    end

    -- Beyond last track: clamp to end of last track
    local last_idx = #track_durations
    return last_idx, track_durations[last_idx]
end

------------------------------------------------------------------------
-- Pure math: convert (track index, offset) to global position (seconds)
--
-- @param track_index  number  1-based track index
-- @param offset       number  seconds into the track
-- @param track_durations  array  duration of each track in seconds
-- @return number  global position in seconds from start of book
------------------------------------------------------------------------
function player.track_offset_to_global(track_index, offset, track_durations)
    if not track_durations or #track_durations == 0 then
        return 0
    end

    if track_index < 1 then
        return 0
    end

    -- Sum durations of all prior tracks
    local global = 0
    for i = 1, math.min(track_index - 1, #track_durations) do
        global = global + track_durations[i]
    end

    -- Add offset, clamped to requested track's duration
    if track_index <= #track_durations then
        local max_offset = track_durations[track_index]
        global = global + math.min(offset or 0, max_offset)
    end

    return global
end

------------------------------------------------------------------------
-- Playback speed presets (PRD §Playback Speed Presets).
-- Tap-to-cycle order: 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2.
-- Not synced to ABS — a local preference only.
------------------------------------------------------------------------
local SPEED_PRESETS = { 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0 }

------------------------------------------------------------------------
-- Next speed in the preset cycle, wrapping back to the first.
-- Unknown/nil input is treated as 1× (the default), so the next tap
-- yields 1.25×.
--
-- @param speed number|nil  current speed multiplier
-- @return number  next preset
------------------------------------------------------------------------
function player.next_speed(speed)
    local base = 1.0
    if speed ~= nil then
        for _, p in ipairs(SPEED_PRESETS) do
            if p == speed then base = speed break end
        end
    end

    for i, p in ipairs(SPEED_PRESETS) do
        if p == base then
            return SPEED_PRESETS[i + 1] or SPEED_PRESETS[1]
        end
    end
    return SPEED_PRESETS[3]  -- 1.25 (fallback; base was 1.0)
end

------------------------------------------------------------------------
-- Render a speed multiplier as a compact badge label.
-- 1.0 → "1×", 1.5 → "1.5×", 0.75 → "0.75×". nil → "1×".
--
-- @param speed number|nil
-- @return string
------------------------------------------------------------------------
function player.format_speed(speed)
    if speed == nil then speed = 1.0 end
    return string.format("%g×", speed)
end

------------------------------------------------------------------------
-- Player instance factory
--
-- @param opts table  Configuration:
--   track_durations  array   duration of each track in seconds
--   file_paths       array   filesystem path for each track
--   start_position   number  initial position (default 0)
--   playback_speed   number  speed multiplier (default 1.0)
--   on_finished      fn      callback when playback reaches end
-- @return table  player instance with all public methods
function player.create(opts)
    opts = opts or {}
    local track_durations = opts.track_durations or {}
    local file_paths = opts.file_paths or {}
    local start_position = opts.start_position or 0
    local playback_speed = opts.playback_speed or 1.0
    local on_finished = opts.on_finished

    -- Select backend.
    --   Explicit "stub" / "inkview" / "ffmpeg" select that backend directly.
    --   Omitted / "auto" / unknown → auto-detect via ffmpeg_backend.is_available(),
    --   falling back to stub (so emulator/tests are unaffected on the dev machine).
    local backend_name = opts.backend
    local backend
    local selected_name = backend_name or "auto"

    local backend_opts = {
        track_durations = track_durations,
        file_paths = file_paths,
        start_position = start_position,
        playback_speed = playback_speed,
        on_finished = on_finished,
    }

    if backend_name == "inkview" then
        local iv = get_inkview_backend()
        backend = iv.new(backend_opts)
        selected_name = "inkview"
    elseif backend_name == "ffmpeg" then
        local fb = get_ffmpeg_backend()
        backend = fb.new(backend_opts)
        selected_name = "ffmpeg"
    elseif backend_name == "stub" then
        local sb = get_stub_backend()
        backend = sb.new(backend_opts)
        selected_name = "stub"
    else
        -- auto-detect: prefer FFmpeg on device, fall back to stub
        local use_ffmpeg = false
        local fb
        local ok_fb = pcall(function() fb = get_ffmpeg_backend() end)
        if ok_fb and fb.is_available() then
            use_ffmpeg = true
        end
        if use_ffmpeg then
            backend = fb.new(backend_opts)
            selected_name = "ffmpeg"
        else
            local sb = get_stub_backend()
            backend = sb.new(backend_opts)
            selected_name = "stub"
        end
    end

    -- Player instance: delegates all calls to the selected backend
    local inst = {}

    function inst:getBackendName() return selected_name end

    function inst:getState() return backend:getState() end
    function inst:getPosition() return backend:getPosition() end
    function inst:getDuration() return backend:getDuration() end
    function inst:getCurrentTrack() return backend:getCurrentTrack() end
    function inst:getPlaybackSpeed() return backend:getPlaybackSpeed() end
    function inst:setPlaybackSpeed(speed) backend:setPlaybackSpeed(speed) end
    function inst:isFinished() return backend:isFinished() end

    function inst:play() backend:play() end
    function inst:pause() backend:pause() end
    function inst:resume() backend:resume() end
    function inst:stop() backend:stop() end
    function inst:close() backend:close() end
    function inst:setPosition(sec) backend:setPosition(sec) end

    -- Stub-specific: advance virtual clock (for testing)
    function inst:_advanceTime(delta)
        if backend._advanceTime then
            backend:_advanceTime(delta)
        end
    end
    return inst
end

------------------------------------------------------------------------
-- Playlist assembly: extract audio file paths from a manifest book entry
--
-- @param book table  manifest entry with local_dir and files array
-- @return array  full file paths for each audio track (empty if none)
------------------------------------------------------------------------
function player.build_playlist(book)
    if not book or not book.local_dir or not book.files then
        return {}
    end

    local paths = {}
    for _, f in ipairs(book.files) do
        local ftype = f.type or "audio"  -- backward compat: no type → audio
        if ftype == "audio" and f.filename then
            table.insert(paths, book.local_dir .. "/" .. f.filename)
        end
    end
    return paths
end

------------------------------------------------------------------------
-- Extract track durations from an API item's audioFiles metadata
--
-- @param item table  API item with audioFiles or media.duration
-- @return array|nil  array of duration numbers, or nil if no data
------------------------------------------------------------------------
function player.extract_track_durations(item)
    if not item then return nil end

    -- Prefer explicit audioFiles with per-track durations
    if item.audioFiles and #item.audioFiles > 0 then
        local durations = {}
        for _, af in ipairs(item.audioFiles) do
            if af.duration and af.duration > 0 then
                table.insert(durations, af.duration)
            end
        end
        if #durations > 0 then return durations end
    end

    -- Fallback: single track from media.total duration
    if item.media and type(item.media.duration) == "number" and item.media.duration > 0 then
        return { item.media.duration }
    end

    return nil
end

------------------------------------------------------------------------
-- Convenience factory: create a player from manifest + API item data
--
-- @param book table  manifest entry (local_dir, files, current_time)
-- @param item table  API item (audioFiles, media.duration for track lengths)
-- @return player_instance|nil  configured player, or nil if no tracks
------------------------------------------------------------------------
function player.create_from_manifest(book, item)
    local file_paths = player.build_playlist(book)
    local track_durations = player.extract_track_durations(item)

    -- If we have file paths but no durations, estimate equal splits
    if #file_paths > 0 and not track_durations then
        track_durations = {}
        for _ = 1, #file_paths do
            table.insert(track_durations, 0)  -- unknown duration
        end
    end

    if not track_durations or #track_durations == 0 then
        return nil
    end

    return player.create({
        track_durations = track_durations,
        file_paths = file_paths,
        start_position = book and book.current_time or 0,
    })
end
return player
