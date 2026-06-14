-- Stub playback backend for absaudio.koplugin
-- Simulates audio playback using a wall-clock timer for emulator use,
-- or a manually-advanced virtual clock for testing.
--
-- Public API (same interface as InkviewBackend):
--   stub_backend.new(opts) → backend instance
--     play(), pause(), resume(), stop(), close()
--     getPosition(), setPosition(sec), getDuration()
--     getCurrentTrack(), getPlaybackSpeed(), setPlaybackSpeed(speed)
--     isFinished()
--     _advanceTime(delta)  — test-only: advance virtual clock (disables real-time mode)
--
-- Internal state machine: "stopped" | "playing" | "paused"
-- Time mode: real-time (default, emulator) | manual (after _advanceTime call, tests)

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

local stub_backend = {}

function stub_backend.new(opts)
    opts = opts or {}
    local track_durations = opts.track_durations or {}
    local start_position = opts.start_position or 0
    local playback_speed = opts.playback_speed or 1.0
    local on_finished = opts.on_finished

    -- Calculate total duration
    local total_duration = 0
    for _, d in ipairs(track_durations) do
        total_duration = total_duration + d
    end

    -- State
    local state = "stopped"
    local position = start_position
    local current_track = 0
    local finished = false

    -- Time tracking: real-time mode (emulator) and manual mode (tests)
    local use_real_time = true   -- false once _advanceTime is called
    local sim_time = 0           -- manual virtual clock (tests)
    local play_start_sim = 0     -- sim_time snapshot at play start
    local play_start_real = 0    -- wall-time snapshot at play start
    local paused_at_position = nil

    ----------------------------------------------------------------
    -- Internal helpers
    ----------------------------------------------------------------
    local function update_current_track()
        if #track_durations == 0 then
            current_track = 0
            return
        end
        local player = require("absaudio/player")
        local t, _ = player.global_to_track_offset(position, track_durations)
        current_track = t
    end

    local function effective_position()
        if state == "playing" and paused_at_position == nil then
            local elapsed
            if use_real_time then
                elapsed = get_wall_time() - play_start_real
            else
                elapsed = sim_time - play_start_sim
            end
            return math.min(position + elapsed * playback_speed, total_duration)
        else
            return position
        end
    end

    local function check_auto_finish()
        local eff = effective_position()
        if eff >= total_duration and total_duration > 0 then
            state = "stopped"
            position = total_duration
            finished = true
            paused_at_position = nil
            update_current_track()
            if on_finished then
                on_finished(position)
            end
            return true
        end
        return false
    end

    -- Backend instance
    local self = {}

    function self:getState() return state end

    function self:getPosition()
        return effective_position()
    end

    function self:getDuration()
        return total_duration
    end

    function self:getCurrentTrack()
        if state == "stopped" then return 0 end
        local eff = effective_position()
        local player_mod = require("absaudio/player")
        local t, _ = player_mod.global_to_track_offset(eff, track_durations)
        return t
    end

    function self:getPlaybackSpeed() return playback_speed end

    function self:setPlaybackSpeed(speed)
        if state == "playing" then
            position = effective_position()
            play_start_sim = sim_time
            play_start_real = get_wall_time()
        end
        playback_speed = speed or 1.0
    end

    function self:isFinished() return finished end

    function self:play()
        if state == "playing" then return end
        position = effective_position()
        paused_at_position = nil
        play_start_sim = sim_time
        play_start_real = get_wall_time()
        state = "playing"
        update_current_track()
        check_auto_finish()
    end

    function self:pause()
        if state ~= "playing" then return end
        position = effective_position()
        paused_at_position = position
        state = "paused"
    end

    function self:resume()
        if state ~= "paused" then return end
        paused_at_position = nil
        play_start_sim = sim_time
        play_start_real = get_wall_time()
        state = "playing"
        check_auto_finish()
    end

    function self:stop()
        state = "stopped"
        position = 0
        current_track = 0
        paused_at_position = nil
    end

    function self:setPosition(global_seconds)
        local clamped = global_seconds
        if clamped < 0 then clamped = 0 end
        if clamped > total_duration then clamped = total_duration end
        position = clamped
        if state == "playing" then
            play_start_sim = sim_time
            play_start_real = get_wall_time()
        elseif state == "paused" then
            paused_at_position = clamped
        end
        update_current_track()
        check_auto_finish()
    end

    function self:close()
        state = "stopped"
        position = 0
        current_track = 0
        finished = false
        paused_at_position = nil
        sim_time = 0
        play_start_sim = 0
        play_start_real = 0
        use_real_time = true
    end

    -- Test-only: advance virtual clock (switches to manual mode)
    function self:_advanceTime(delta)
        use_real_time = false
        sim_time = sim_time + delta
        if state == "playing" then
            check_auto_finish()
        end
    end

    update_current_track()
    return self
end

return stub_backend
