-- FFmpeg playback backend for absaudio.koplugin (issue #33, audio slice B)
--
-- Backend contract skeleton for real in-app audio on PocketBook via libaudio-engine.so
-- (FFmpeg decode + ALSA output). This slice implements the transport state machine,
-- position bookkeeping, and the is_available() selection hook — all fully unit-testable
-- on the dev Mac with the FFI decode/output layer MOCKED OUT. Real FFmpeg decode, the
-- ALSA output pump, and the atempo speed graph land in later slices (#34+).
--
-- Implements the SAME public contract as stub_backend.lua / inkview_backend.lua so it
-- drops into player.create()'s strategy unchanged:
--   ffmpeg_backend.new(opts) → backend instance
--     play(), pause(), resume(), stop(), close()
--     getPosition(), setPosition(sec), getDuration()
--     getCurrentTrack(), getPlaybackSpeed(), setPlaybackSpeed(speed)
--     isFinished(), getState()
--   ffmpeg_backend.is_available() → bool   (guarded FFI probe; false on dev)
--
-- opts:
--   track_durations   array    duration of each track in seconds
--   file_paths        array    filesystem path for each track (unused by mocked decode)
--   start_position    number   initial position in seconds (default 0)
--   playback_speed    number   speed multiplier (default 1.0)
--   on_finished       fn       callback(final_position_seconds) when playback reaches end
--   buffer_capacity   number   PCM ring-buffer capacity in bytes (default 1<<20 ≈ 1 MiB)
--   ffi_probe         fn       override is_available() probe for tests
--
-- Position bookkeeping delegates to slice A's pure library (time_math): the internal
-- position is tracked in milliseconds (the natural FFmpeg PTS unit) and converted to
-- seconds via time_math.ms_to_seconds(), clamped to duration via time_math.clamp(). A
-- ring_buffer (also slice A) is instantiated at construction for the decoupled
-- decode/output design; decode does not feed it yet (mocked).
--
-- Time mode mirrors stub_backend: real-time wall-clock for emulator use, or a
-- manually-advanced virtual clock for tests (after _advanceTime is called).
--
-- Transport state machine: "stopped" | "playing" | "paused"

local time_math = require("absaudio/time_math")
local ring_buffer = require("absaudio/ring_buffer")

------------------------------------------------------------------------
-- Wall-clock resolver: prefer KOReader's high-resolution time module,
-- fall back to os.time() (1-second resolution) for standalone/test use.
------------------------------------------------------------------------
local get_wall_time
do
    local ok, time_mod = pcall(require, "ui/time")
    if ok and time_mod.now then
        get_wall_time = function()
            return time_mod.to_number(time_mod.now())
        end
    else
        get_wall_time = function() return os.time() end
    end
end

------------------------------------------------------------------------
-- Default is_available() probe: guarded FFI load of the PocketBook audio toolkit.
-- Returns true only if libaudio-engine.so loads (device); false on the dev Mac.
-- All FFI access is pcall-guarded so a missing/undefined symbol never crashes
-- (lesson from the IsPlayingMP3 probe crash).
-- The real cdef + key-symbol validation lands in the FFI cdef slice (#34); here
-- a successful library load is a sufficient "available" signal.
------------------------------------------------------------------------
local default_ffi_probe
do
    local probed = false
    local available = false
    default_ffi_probe = function()
        if probed then return available end
        probed = true
        local ok_ffi, ffi = pcall(require, "ffi")
        if not ok_ffi then available = false return false end
        -- ffi.load is pcall-guarded: a missing .so errors rather than crashes
        local lib_ok = pcall(function() ffi.load("audio-engine") end)
        available = lib_ok and true or false
        return available
    end
end

local ffmpeg_backend = {}

-- Module-level probe override (for tests / forced device mode).
local probe_override = nil

------------------------------------------------------------------------
-- Whether the FFmpeg backend can run in the current environment.
-- False on the dev Mac; true on a PocketBook once libaudio-engine.so loads.
-- Mockable: set ffmpeg_backend._set_probe_override(fn) or pass opts.ffi_probe.
-- @return bool
------------------------------------------------------------------------
function ffmpeg_backend.is_available()
    if probe_override then return probe_override() end
    return default_ffi_probe()
end

-- Test-only: override the module-level availability probe.
-- @param fn function|nil  nil restores the default guarded probe
function ffmpeg_backend._set_probe_override(fn)
    probe_override = fn
end

------------------------------------------------------------------------
-- Create a new FFmpeg backend instance.
-- @param opts table  (see module header)
-- @return table  backend instance implementing the full contract
------------------------------------------------------------------------
function ffmpeg_backend.new(opts)
    opts = opts or {}
    local track_durations = opts.track_durations or {}
    local file_paths = opts.file_paths or {}
    local start_position = opts.start_position or 0
    local playback_speed = opts.playback_speed or 1.0
    local on_finished = opts.on_finished
    local buffer_capacity = opts.buffer_capacity or (1024 * 1024)
    local ffi_probe = opts.ffi_probe

    -- Total duration (seconds)
    local total_duration = 0
    for _, d in ipairs(track_durations) do
        total_duration = total_duration + d
    end
    local duration_ms = time_math.seconds_to_ms(total_duration)

    -- Ring buffer for the decoupled decode/output design (mocked this slice)
    local rb = ring_buffer.new(buffer_capacity)

    -- Transport state
    local state = "stopped"
    local position_ms = time_math.seconds_to_ms(start_position)
    local finished = false

    -- Time tracking: real-time mode (emulator) and manual mode (tests)
    local use_real_time = true   -- false once _advanceTime is called
    local sim_time = 0           -- manual virtual clock (seconds, tests)
    local play_start_sim = 0
    local play_start_real = 0

    ----------------------------------------------------------------
    -- Internal helpers
    ----------------------------------------------------------------
    local function effective_position_ms()
        if state == "playing" then
            local elapsed
            if use_real_time then
                elapsed = get_wall_time() - play_start_real
            else
                elapsed = sim_time - play_start_sim
            end
            local advanced = time_math.seconds_to_ms(elapsed * playback_speed)
            return time_math.clamp(position_ms + advanced, duration_ms)
        else
            return time_math.clamp(position_ms, duration_ms)
        end
    end

    local function check_auto_finish()
        if duration_ms <= 0 then return false end
        local eff = effective_position_ms()
        if eff >= duration_ms then
            state = "stopped"
            position_ms = duration_ms
            finished = true
            if on_finished then
                on_finished(time_math.ms_to_seconds(position_ms))
            end
            return true
        end
        return false
    end

    -- Snapshot the clock baseline so effective_position_ms() measures elapsed from now.
    local function rebase_clock()
        play_start_sim = sim_time
        play_start_real = get_wall_time()
    end

    ----------------------------------------------------------------
    -- Backend instance
    ----------------------------------------------------------------
    local self = {}

    function self:getState() return state end
    function self:getCurrentTrack()
        if state == "stopped" then return 0 end
        local player_mod = require("absaudio/player")
        local t, _ = player_mod.global_to_track_offset(
            time_math.ms_to_seconds(effective_position_ms()), track_durations)
        return t
    end
    function self:getPlaybackSpeed() return playback_speed end
    function self:setPlaybackSpeed(speed)
        if state == "playing" then
            position_ms = effective_position_ms()
            rebase_clock()
        end
        playback_speed = speed or 1.0
    end
    function self:getPosition()
        return time_math.ms_to_seconds(effective_position_ms())
    end
    function self:setPosition(global_seconds)
        local sec = global_seconds or 0
        if sec < 0 then sec = 0 end
        position_ms = time_math.clamp(time_math.seconds_to_ms(sec), duration_ms)
        if state == "playing" then
            rebase_clock()
        end
        check_auto_finish()
    end
    function self:getDuration() return total_duration end
    function self:isFinished() return finished end
    function self:getRingBuffer() return rb end
    function self:_advanceTime(delta)
        use_real_time = false
        sim_time = sim_time + delta
        if state == "playing" then check_auto_finish() end
    end

    function self:is_available()
        if ffi_probe then return ffi_probe() end
        return ffmpeg_backend.is_available()
    end

    function self:play()
        if state == "playing" then return end
        position_ms = effective_position_ms()
        rebase_clock()
        state = "playing"
        check_auto_finish()
    end

    function self:pause()
        if state ~= "playing" then return end
        position_ms = effective_position_ms()
        state = "paused"
    end

    function self:resume()
        if state ~= "paused" then return end
        rebase_clock()
        state = "playing"
        check_auto_finish()
    end

    function self:stop()
        state = "stopped"
        position_ms = 0
    end

    function self:close()
        state = "stopped"
        position_ms = 0
        finished = false
        use_real_time = true
        sim_time = 0
        play_start_sim = 0
        play_start_real = 0
    end

    return self
end

return ffmpeg_backend
