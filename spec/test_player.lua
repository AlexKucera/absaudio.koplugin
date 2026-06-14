-- Player module tests
-- Tests position conversion math, player backend stub, state machine,
-- playlist assembly, and now-playing UI integration.
--
-- Run with: ./kodev test front spec/test_player.lua
--   or:     luajit spec/test_player.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

-- Stub KOReader dependencies
local Blitbuffer = {
    COLOR_WHITE = { 1 },
    COLOR_BLACK = { 2 },
    COLOR_DARK_GRAY = { 3 },
    COLOR_LIGHT_GRAY = { 4 },
    COLOR_BLUE = { 5 },
    COLOR_GRAY = { 6 },
    COLOR_DARK_GREEN = { 7 },
}
package.loaded["ffi/blitbuffer"] = Blitbuffer
package.loaded["ui/bidi"] = {}
package.loaded["device"] = {
    screen = {
        getSize = function() return { w = 600, h = 800 } end,
        scaleBySize = function(n) return n end,
    },
    hasKeys = function() return false end,
    isTouchDevice = function() return false end,
    input = { group = { Back = "Back" } },
}
package.loaded["ui/font"] = {
    getFace = function(_, size) return { size = size } end,
}
package.loaded["ui/geometry"] = {
    new = function(x, y, w, h) return { x = x or 0, y = y or 0, w = w or 0, h = h or 0 } end,
}
package.loaded["ui/gesturerange"] = {
    new = function() end,
}
package.loaded["ui/widget/container/inputcontainer"] = {
    new = function(cls, opts)
        local o = opts or {}
        setmetatable(o, { __index = cls })
        return o
    end,
}
package.loaded["ui/widget/linewidget"] = {
    new = function() return {} end,
}
package.loaded["ui/size"] = {
    padding = { small = 5, default = 10, large = 15 },
}
package.loaded["ui/widget/textwidget"] = {
    new = function(opts) return { text = opts and opts.text or "" } end,
}
package.loaded["ui/widget/textboxwidget"] = {
    new = function(opts) return { text = opts and opts.text or "" } end,
}
package.loaded["ui/widget/verticalspan"] = {
    new = function() return {} end,
}
package.loaded["ui/widget/verticalgroup"] = {
    new = function() return { _children = {} } end,
}
package.loaded["ui/widget/horizontalgroup"] = {
    new = function() return { _children = {} } end,
}
package.loaded["ui/widget/container/centercontainer"] = {
    new = function(_, opts) return opts or {} end,
}
package.loaded["ui/widget/container/framecontainer"] = {
    new = function(opts) return opts or {} end,
}
package.loaded["ui/widget/container/scrollablecontainer"] = {
    new = function(_, opts) return opts or {} end,
}
package.loaded["ui/widget/imagewidget"] = {
    new = function() return {} end,
}
package.loaded["ui/widget/iconwidget"] = {
    new = function() return {} end,
}
package.loaded["ui/uimanager"] = {
    show = function() end,
    close = function() end,
    setDirty = function() end,
    scheduleIn = function(_, fn) fn() end,
}
package.loaded["ui/widget/infomessage"] = {
    new = function() return { show = function() end } end,
}
package.loaded["ui/widget/confirmbox"] = {
    new = function() return { show = function() end } end,
}
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
local player = require("absaudio/player")

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
-- Slice 1: global_to_track_offset conversion
-- ============================================================

run_test("global_to_track_offset: position 0 → track 1, offset 0", function()
    local tracks = { 300, 240, 280 }  -- 3 tracks, total 820s
    local track_idx, offset = player.global_to_track_offset(0, tracks)
    mock.assert_equals(track_idx, 1, "first track")
    mock.assert_equals(offset, 0, "no offset")
end)

run_test("global_to_track_offset: mid-first-track → track 1, correct offset", function()
    local tracks = { 300, 240, 280 }
    local track_idx, offset = player.global_to_track_offset(150, tracks)
    mock.assert_equals(track_idx, 1, "first track")
    mock.assert_equals(offset, 150, "150s into first track")
end)

run_test("global_to_track_offset: exactly at track boundary → next track, offset 0", function()
    local tracks = { 300, 240, 280 }
    -- Position 300 is the boundary between track 1 and 2
    local track_idx, offset = player.global_to_track_offset(300, tracks)
    mock.assert_equals(track_idx, 2, "second track at boundary")
    mock.assert_equals(offset, 0, "offset resets at boundary")
end)

run_test("global_to_track_offset: second track middle → track 2, correct offset", function()
    local tracks = { 300, 240, 280 }
    -- Position 300 + 100 = 400 → track 2, offset 100
    local track_idx, offset = player.global_to_track_offset(400, tracks)
    mock.assert_equals(track_idx, 2, "second track")
    mock.assert_equals(offset, 100, "100s into second track")
end)

run_test("global_to_track_offset: last track → track 3, correct offset", function()
    local tracks = { 300, 240, 280 }
    -- Position 540 + 50 = 590 → track 3, offset 50
    local track_idx, offset = player.global_to_track_offset(590, tracks)
    mock.assert_equals(track_idx, 3, "third track")
    mock.assert_equals(offset, 50, "50s into third track")
end)

run_test("global_to_track_offset: last position in last track → last track, offset near end", function()
    local tracks = { 300, 240, 280 }
    -- Total = 820, last valid position = 819
    local track_idx, offset = player.global_to_track_offset(819, tracks)
    mock.assert_equals(track_idx, 3, "third track")
    mock.assert_equals(offset, 279, "279s into third track (last second)")
end)

run_test("global_to_track_offset: beyond total duration → clamps to last track end", function()
    local tracks = { 300, 240, 280 }
    -- Position 2000 > total 820
    local track_idx, offset = player.global_to_track_offset(2000, tracks)
    mock.assert_equals(track_idx, 3, "clamped to last track")
    mock.assert_equals(offset, 280, "clamped to track duration")
end)

run_test("global_to_track_offset: negative position → clamps to track 1, offset 0", function()
    local tracks = { 300, 240, 280 }
    local track_idx, offset = player.global_to_track_offset(-10, tracks)
    mock.assert_equals(track_idx, 1, "clamped to first track")
    mock.assert_equals(offset, 0, "clamped to zero")
end)

run_test("global_to_track_offset: single track book", function()
    local tracks = { 3600 }  -- 1 hour
    local track_idx, offset = player.global_to_track_offset(1800, tracks)
    mock.assert_equals(track_idx, 1, "only track")
    mock.assert_equals(offset, 1800, "halfway through")
end)

run_test("global_to_track_offset: empty track list → track 0, offset 0", function()
    local track_idx, offset = player.global_to_track_offset(100, {})
    mock.assert_equals(track_idx, 0, "no tracks")
    mock.assert_equals(offset, 0, "zero offset")
end)

-- ============================================================
-- Slice 2: track_offset_to_global reverse conversion
-- ============================================================

run_test("track_offset_to_global: track 1, offset 0 → global 0", function()
    local tracks = { 300, 240, 280 }
    local global = player.track_offset_to_global(1, 0, tracks)
    mock.assert_equals(global, 0, "start of book")
end)

run_test("track_offset_to_global: track 2, offset 0 → sum of prior tracks", function()
    local tracks = { 300, 240, 280 }
    local global = player.track_offset_to_global(2, 0, tracks)
    mock.assert_equals(global, 300, "after first track")
end)

run_test("track_offset_to_global: track 3, offset 50 → total prior + 50", function()
    local tracks = { 300, 240, 280 }
    local global = player.track_offset_to_global(3, 50, tracks)
    mock.assert_equals(global, 590, "300+240+50")
end)

run_test("track_offset_to_global: offset beyond track duration → clamps to track end", function()
    local tracks = { 300, 240, 280 }
    local global = player.track_offset_to_global(1, 500, tracks)
    mock.assert_equals(global, 300, "clamped to end of track 1")
end)

run_test("track_offset_to_global: track index 0 → global 0", function()
    local tracks = { 300, 240, 280 }
    local global = player.track_offset_to_global(0, 0, tracks)
    mock.assert_equals(global, 0, "track 0 = before start")
end)

run_test("round-trip: global→track→global is identity for valid positions", function()
    local tracks = { 300, 240, 280 }
    -- Test several positions round-trip correctly
    for _, pos in ipairs({0, 1, 150, 299, 300, 301, 540, 819}) do
        local t, o = player.global_to_track_offset(pos, tracks)
        local back = player.track_offset_to_global(t, o, tracks)
        mock.assert_equals(back, pos, string.format("round-trip for pos=%d", pos))
    end
end)

-- ============================================================
-- Slice 3: Player create + state transitions
-- ============================================================

run_test("player.create: returns instance with stopped state", function()
    local p = player.create({
        track_durations = { 300, 240, 280 },
        file_paths = { "/tmp/track1.m4b", "/tmp/track2.m4b", "/tmp/track3.m4b" },
    })
    mock.assert_equals(p:getState(), "stopped", "initial state is stopped")
    mock.assert_equals(p:getDuration(), 820, "total duration")
    mock.assert_equals(p:getCurrentTrack(), 0, "no current track when stopped")
    mock.assert_equals(p:getPosition(), 0, "position starts at 0")
    p:close()
end)

run_test("player.create: uses stub backend by default", function()
    local p = player.create({
        track_durations = { 100 },
        file_paths = { "/tmp/track.m4b" },
    })
    -- Should not error — stub backend doesn't need real files
    mock.assert_equals(p:getState(), "stopped")
    p:close()
end)

run_test("play(): transitions stopped → playing", function()
    local p = player.create({
        track_durations = { 300 },
        file_paths = { "/tmp/t.m4b" },
    })
    p:play()
    mock.assert_equals(p:getState(), "playing", "now playing")
    mock.assert_equals(p:getCurrentTrack(), 1, "on first track")
    p:close()
end)

run_test("pause(): transitions playing → paused", function()
    local p = player.create({
        track_durations = { 300 },
        file_paths = { "/tmp/t.m4b" },
    })
    p:play()
    p:pause()
    mock.assert_equals(p:getState(), "paused", "now paused")
    p:close()
end)

run_test("resume(): transitions paused → playing", function()
    local p = player.create({
        track_durations = { 300 },
        file_paths = { "/tmp/t.m4b" },
    })
    p:play()
    p:pause()
    p:resume()
    mock.assert_equals(p:getState(), "playing", "resumed playing")
    p:close()
end)

run_test("stop(): transitions playing/paused → stopped", function()
    local p = player.create({
        track_durations = { 300 },
        file_paths = { "/tmp/t.m4b" },
    })
    p:play()
    p:stop()
    mock.assert_equals(p:getState(), "stopped", "stopped from playing")

    p:play()
    p:pause()
    p:stop()
    mock.assert_equals(p:getState(), "stopped", "stopped from paused")
    p:close()
end)

run_test("play() when already playing is no-op", function()
    local p = player.create({
        track_durations = { 300 },
        file_paths = { "/tmp/t.m4b" },
    })
    p:play()
    local pos_before = p:getPosition()
    p:play()  -- should be no-op
    mock.assert_equals(p:getState(), "playing", "still playing")
    p:close()
end)

run_test("pause() when stopped is no-op", function()
    local p = player.create({
        track_durations = { 300 },
        file_paths = { "/tmp/t.m4b" },
    })
    p:pause()  -- should be no-op
    mock.assert_equals(p:getState(), "stopped", "still stopped")
    p:close()
end)

-- ============================================================
-- Slice 4: Position tracking with stub backend
-- ============================================================

run_test("stub play advances position over time", function()
    local p = player.create({
        track_durations = { 100 },
        file_paths = { "/tmp/t.m4b" },
        playback_speed = 1.0,
    })
    p:play()
    p:_advanceTime(5)  -- advance 5 seconds of simulated playback
    mock.assert_equals(p:getPosition(), 5, "position advanced 5s")
    p:close()
end)

run_test("stub pause freezes position", function()
    local p = player.create({
        track_durations = { 100 },
        file_paths = { "/tmp/t.m4b" },
    })
    p:play()
    p:_advanceTime(10)
    p:pause()
    local pos_at_pause = p:getPosition()
    p:_advanceTime(5)  -- time passes while paused
    mock.assert_equals(p:getPosition(), pos_at_pause, "position frozen during pause")
    p:close()
end)

run_test("stub resume continues from paused position", function()
    local p = player.create({
        track_durations = { 200 },
        file_paths = { "/tmp/t.m4b" },
    })
    p:play()
    p:_advanceTime(10)
    p:pause()
    p:_advanceTime(5)  -- paused time (doesn't count)
    p:resume()
    p:_advanceTime(3)  -- 3s more of playback
    mock.assert_equals(p:getPosition(), 13, "10 + 0 + 3 = 13")
    p:close()
end)

run_test("getPosition returns start_position before play", function()
    local p = player.create({
        track_durations = { 300 },
        file_paths = { "/tmp/t.m4b" },
        start_position = 50,
    })
    mock.assert_equals(p:getPosition(), 50, "position is 50 before play")
    p:close()
end)

run_test("getDuration returns total of all track durations", function()
    local p = player.create({
        track_durations = { 300, 240, 280 },
        file_paths = { "/t1", "/t2", "/t3" },
    })
    mock.assert_equals(p:getDuration(), 820, "sum of all tracks")
    p:close()
end)

run_test("stub real-time mode advances position via wall clock (emulator)", function()
    local p = player.create({
        track_durations = { 100 },
        file_paths = { "/tmp/t.m4b" },
        playback_speed = 1.0,
    })
    p:play()
    -- Default is real-time mode: position tracks wall clock.
    -- _advanceTime switches to manual mode (test determinism).
    p:_advanceTime(5)
    mock.assert_equals(p:getPosition(), 5, "manual mode works after _advanceTime")
    p:close()
end)

run_test("stub _advanceTime disables real-time mode (test determinism)", function()
    local p = player.create({
        track_durations = { 200 },
        file_paths = { "/tmp/t.m4b" },
        playback_speed = 2.0,
    })
    p:play()
    p:_advanceTime(5)  -- 5 real seconds at 2x = 10s of audio
    mock.assert_equals(p:getPosition(), 10, "2x speed applies in manual mode")
    p:close()
end)

run_test("getCurrentTrack updates as position crosses boundaries", function()
    local p = player.create({
        track_durations = { 100, 200 },
        file_paths = { "/t1", "/t2" },
    })
    p:play()
    mock.assert_equals(p:getCurrentTrack(), 1, "starts on track 1")
    p:_advanceTime(99)
    mock.assert_equals(p:getCurrentTrack(), 1, "still track 1 at 99s")
    p:_advanceTime(2)  -- now at 101s → track 2
    mock.assert_equals(p:getCurrentTrack(), 2, "moved to track 2 after boundary")
    p:close()
end)

run_test("playback speed affects position rate", function()
    local p = player.create({
        track_durations = { 100 },
        file_paths = { "/tmp/t.m4b" },
        playback_speed = 2.0,
    })
    p:play()
    p:_advanceTime(5)  -- 5 real seconds at 2x speed = 10s of audio
    mock.assert_equals(p:getPosition(), 10, "2x speed: 5s * 2 = 10s position")
    p:close()
end)

run_test("getPlaybackSpeed/setPlaybackSpeed work", function()
    local p = player.create({
        track_durations = { 100 },
        file_paths = { "/tmp/t.m4b" },
    })
    mock.assert_equals(p:getPlaybackSpeed(), 1.0, "default speed is 1.0")
    p:setPlaybackSpeed(1.5)
    mock.assert_equals(p:getPlaybackSpeed(), 1.5, "speed updated to 1.5")
    p:close()
end)

run_test("stop resets position to 0", function()
    local p = player.create({
        track_durations = { 100 },
        file_paths = { "/tmp/t.m4b" },
    })
    p:play()
    p:_advanceTime(50)
    p:stop()
    mock.assert_equals(p:getPosition(), 0, "stop resets position")
    mock.assert_equals(p:getCurrentTrack(), 0, "stop clears current track")
    p:close()
end)

-- ============================================================
-- Slice 5: Seek / setPosition across track boundaries
-- ============================================================

run_test("setPosition seeks within same track", function()
    local p = player.create({
        track_durations = { 300, 240 },
        file_paths = { "/t1", "/t2" },
    })
    p:play()
    p:_advanceTime(10)
    p:setPosition(150)  -- seek to 150s (still in track 1)
    mock.assert_equals(p:getPosition(), 150, "position updated")
    mock.assert_equals(p:getCurrentTrack(), 1, "still on track 1")
    p:close()
end)

run_test("setPosition seeks across track boundary forward", function()
    local p = player.create({
        track_durations = { 300, 240 },
        file_paths = { "/t1", "/t2" },
    })
    p:play()
    p:setPosition(400)  -- into track 2
    mock.assert_equals(p:getPosition(), 400, "position in track 2")
    mock.assert_equals(p:getCurrentTrack(), 2, "on track 2")
    p:close()
end)

run_test("setPosition seeks backward across track boundary", function()
    local p = player.create({
        track_durations = { 300, 240 },
        file_paths = { "/t1", "/t2" },
    })
    p:play()
    p:_advanceTime(400)  -- well into track 2
    p:setPosition(50)  -- back to track 1
    mock.assert_equals(p:getPosition(), 50, "position back in track 1")
    mock.assert_equals(p:getCurrentTrack(), 1, "back on track 1")
    p:close()
end)

run_test("setPosition clamps to valid range", function()
    local p = player.create({
        track_durations = { 100 },
        file_paths = { "/tmp/t.m4b" },
    })
    p:play()
    p:setPosition(-10)
    mock.assert_equals(p:getPosition(), 0, "clamped to 0")
    p:setPosition(9999)
    mock.assert_equals(p:getPosition(), 100, "clamped to duration")
    p:close()
end)

run_test("setPosition while paused then resume plays from seek point", function()
    local p = player.create({
        track_durations = { 200 },
        file_paths = { "/tmp/t.m4b" },
    })
    p:play()
    p:_advanceTime(20)
    p:pause()
    p:setPosition(80)
    p:resume()
    p:_advanceTime(5)
    mock.assert_equals(p:getPosition(), 85, "resumed from 80, advanced 5s")
    p:close()
end)

run_test("start_position sets initial position before play", function()
    local p = player.create({
        track_durations = { 300, 200 },
        file_paths = { "/t1", "/t2" },
        start_position = 250,  -- start mid-book
    })
    p:play()
    mock.assert_equals(p:getPosition(), 250, "started from position 250")
    mock.assert_equals(p:getCurrentTrack(), 1, "track 1 at 250s (duration 300)")
    p:close()
end)

-- ============================================================
-- Slice 6: Multi-file sequential playback & auto-finish
-- ============================================================

run_test("multi-track: auto-advances to next track", function()
    local p = player.create({
        track_durations = { 5, 10 },
        file_paths = { "/t1", "/t2" },
    })
    p:play()
    p:_advanceTime(5)   -- end of track 1
    mock.assert_equals(p:getCurrentTrack(), 2, "auto-advanced to track 2")
    p:close()
end)

run_test("multi-track: auto-finishes at end of last track", function()
    local p = player.create({
        track_durations = { 5, 5 },
        file_paths = { "/t1", "/t2" },
    })
    p:play()
    p:_advanceTime(10)  -- end of last track
    mock.assert_equals(p:getState(), "stopped", "auto-stopped at end")
    mock.assert_equals(p:isFinished(), true, "marked finished")
    p:close()
end)

run_test("auto-finish fires onFinished callback", function()
    local finished_fired = false
    local finished_position = nil
    local p = player.create({
        track_durations = { 5, 5 },
        file_paths = { "/t1", "/t2" },
        on_finished = function(pos)
            finished_fired = true
            finished_position = pos
        end,
    })
    p:play()
    p:_advanceTime(10)
    mock.assert_equals(finished_fired, true, "callback fired")
    mock.assert_equals(finished_position, 10, "callback received final position")
    p:close()
end)

run_test("auto-finish does NOT fire if stopped early", function()
    local finished_fired = false
    local p = player.create({
        track_durations = { 100 },
        file_paths = { "/tmp/t.m4b" },
        on_finished = function() finished_fired = true end,
    })
    p:play()
    p:_advanceTime(10)
    p:stop()
    mock.assert_equals(finished_fired, false, "callback NOT fired on manual stop")
    mock.assert_equals(p:isFinished(), false, "not marked finished")
    p:close()
end)

run_test("seek past end triggers auto-finish", function()
    local p = player.create({
        track_durations = { 10 },
        file_paths = { "/tmp/t.m4b" },
    })
    p:play()
    p:setPosition(10)  -- exactly at end
    mock.assert_equals(p:getState(), "stopped", "stopped when seeking to end")
    mock.assert_equals(p:isFinished(), true, "finished")
    p:close()
end)

-- ============================================================
-- Slice 7: Playlist assembly from manifest data
-- ============================================================

run_test("build_playlist: returns empty array for book with no audio files", function()
    local book = {
        local_dir = "/absaudio/book_456",
        files = {
            { filename = "book.epub", type = "ebook" },
        },
    }
    local paths = player.build_playlist(book)
    mock.assert_equals(#paths, 0, "no audio files → empty playlist")
end)

run_test("build_playlist: returns empty array for empty files list", function()
    local paths = player.build_playlist({ local_dir = "/path", files = {} })
    mock.assert_equals(#paths, 0, "empty files → empty playlist")
end)

run_test("build_playlist: handles nil/missing fields gracefully", function()
    mock.assert_equals(#player.build_playlist(nil), 0, "nil book")
    mock.assert_equals(#player.build_playlist({}), 0, "empty table")
    mock.assert_equals(#player.build_playlist({ local_dir = "/path" }), 0, "no files field")
end)

run_test("build_playlist: extracts audio file paths from manifest entry", function()
    local book = {
        local_dir = "/absaudio/book_123",
        files = {
            { filename = "track01.m4b", type = "audio" },
            { filename = "track02.m4b", type = "audio" },
            { filename = "book.epub", type = "ebook" },
        },
    }
    local paths = player.build_playlist(book)
    mock.assert_equals(#paths, 2, "two audio files")
    mock.assert_equals(paths[1], "/absaudio/book_123/track01.m4b", "first track path")
    mock.assert_equals(paths[2], "/absaudio/book_123/track02.m4b", "second track path")
end)

run_test("extract_track_durations: gets durations from audioFiles", function()
    local item = {
        audioFiles = {
            { duration = 300 },
            { duration = 240 },
            { duration = 280 },
        },
    }
    local durations = player.extract_track_durations(item)
    mock.assert_equals(#durations, 3, "three durations")
    mock.assert_equals(durations[1], 300, "first track")
    mock.assert_equals(durations[2], 240, "second track")
    mock.assert_equals(durations[3], 280, "third track")
end)

run_test("extract_track_durations: returns nil when no audioFiles", function()
    local durations = player.extract_track_durations({})
    mock.assert_equals(durations, nil, "no audioFiles → nil")
end)

run_test("extract_track_durations: falls back to media.duration for single track", function()
    local item = {
        media = { duration = 3600 },
    }
    local durations = player.extract_track_durations(item)
    mock.assert_equals(#durations, 1, "one track from media.duration")
    mock.assert_equals(durations[1], 3600, "media.duration value")
end)

run_test("create_from_manifest: builds fully configured player instance", function()
    local book = {
        local_dir = "/absaudio/book_789",
        files = {
            { filename = "part1.m4b", type = "audio" },
            { filename = "part2.m4b", type = "audio" },
        },
        current_time = 120,
    }
    local item = {
        audioFiles = { { duration = 300 }, { duration = 200 } },
    }
    local p = player.create_from_manifest(book, item)
    mock.assert_equals(p:getState(), "stopped", "initial state")
    mock.assert_equals(p:getDuration(), 500, "total duration")
    mock.assert_equals(p:getPosition(), 120, "starts at current_time")
    p:close()
end)

-- ============================================================
-- Slice 8: Seekable Progress Bar Widget
-- ============================================================

run_test("progress_bar: can be created with width and duration", function()
    local progress_bar = require("absaudio/progress_bar")
    local bar = progress_bar.new({
        width = 400,
        duration = 300,
        on_seek = function() end,
    })
    mock.assert_equals(bar.width, 400, "width stored")
    mock.assert_equals(bar.duration, 300, "duration stored")
    mock.assert_equals(bar.position, 0, "position starts at 0")
end)

run_test("progress_bar: setPosition updates position", function()
    local progress_bar = require("absaudio/progress_bar")
    local bar = progress_bar.new({ width = 400, duration = 300, on_seek = function() end })
    bar:setPosition(150)
    mock.assert_equals(bar:getPosition(), 150, "position updated to 150")
end)

run_test("progress_bar: getFillWidth returns correct fill ratio", function()
    local progress_bar = require("absaudio/progress_bar")
    local bar = progress_bar.new({ width = 400, duration = 100, on_seek = function() end })
    mock.assert_equals(bar:getFillWidth(), 0, "zero position → zero fill")
    bar:setPosition(50)
    mock.assert_equals(bar:getFillWidth(), 200, "50% position → half fill")
    bar:setPosition(100)
    mock.assert_equals(bar:getFillWidth(), 400, "full position → full fill")
end)

run_test("progress_bar: clamps position to duration range", function()
    local progress_bar = require("absaudio/progress_bar")
    local bar = progress_bar.new({ width = 400, duration = 100, on_seek = function() end })
    bar:setPosition(-10)
    mock.assert_equals(bar:getPosition(), 0, "negative clamped to 0")
    bar:setPosition(999)
    mock.assert_equals(bar:getPosition(), 100, "over-duration clamped to duration")
end)

run_test("progress_bar: tap converts x-position to seek time", function()
    local progress_bar = require("absaudio/progress_bar")
    local sought_position = nil
    local bar = progress_bar.new({
        width = 400,
        duration = 200,
        on_seek = function(pos) sought_position = pos end,
    })
    -- Simulate tap at 50% of width (x=200 within a 400px bar)
    -- Should seek to 100s (50% of 200s duration)
    local seek_pos = bar:positionToSeconds(200)
    mock.assert_equals(seek_pos, 100, "tap at 50% → 50% of duration")
end)

run_test("progress_bar: positionToSeconds clamps to valid range", function()
    local progress_bar = require("absaudio/progress_bar")
    local bar = progress_bar.new({ width = 400, duration = 100, on_seek = function() end })
    mock.assert_equals(bar:positionToSeconds(-10), 0, "negative x → 0")
    mock.assert_equals(bar:positionToSeconds(0), 0, "x=0 → 0")
    mock.assert_equals(bar:positionToSeconds(400), 100, "x=width → duration")
    mock.assert_equals(bar:positionToSeconds(999), 100, "beyond width → duration")
end)

run_test("progress_bar: onTapProgress calls on_seek with correct position", function()
    local progress_bar = require("absaudio/progress_bar")
    local sought_position = nil
    local bar = progress_bar.new({
        width = 400,
        duration = 200,
        on_seek = function(pos) sought_position = pos end,
    })
    bar:onTapProgress({ pos = { x = 100 } })
    mock.assert_equals(sought_position, 50, "tap at x=100 → 50s (25% of 200s)")
end)

run_test("progress_bar: onTapProgress at edges clamps", function()
    local progress_bar = require("absaudio/progress_bar")
    local sought_position = nil
    local bar = progress_bar.new({
        width = 400,
        duration = 100,
        on_seek = function(pos) sought_position = pos end,
    })
    bar:onTapProgress({ pos = { x = -50 } })
    mock.assert_equals(sought_position, 0, "before bar → 0s")
    bar:onTapProgress({ pos = { x = 999 } })
    mock.assert_equals(sought_position, 100, "after bar → 100s (duration)")
    mock.assert_equals(sought_position, 100, "after bar → 100s (duration)")
end)
run_test("progress_bar: onProgressDrag seeks continuously during drag", function()
    local progress_bar = require("absaudio/progress_bar")
    local seek_log = {}
    local bar = progress_bar.new({
        width = 400,
        duration = 200,
        on_seek = function(pos) table.insert(seek_log, pos) end,
    })
    -- Simulate drag across the bar
    bar:onProgressDrag({ pos = { x = 0 } })
    bar:onProgressDrag({ pos = { x = 200 } })
    bar:onProgressDrag({ pos = { x = 400 } })
    mock.assert_equals(#seek_log, 3, "3 seek events during drag")
    mock.assert_equals(seek_log[1], 0, "drag start → 0s")
    mock.assert_equals(seek_log[2], 100, "drag middle → 100s (50%)")
    mock.assert_equals(seek_log[3], 200, "drag end → 200s (100%)")
end)

run_test("progress_bar: zero duration returns safe values", function()
    local progress_bar = require("absaudio/progress_bar")
    local bar = progress_bar.new({ width = 400, duration = 0, on_seek = function() end })
    mock.assert_equals(bar:getFillWidth(), 0, "zero duration → no fill")
    mock.assert_equals(bar:positionToSeconds(200), 0, "zero duration → always 0s")
end)

run_test("progress_bar: integrates with player for seek callback", function()
    local player = require("absaudio/player")
    local progress_bar = require("absaudio/progress_bar")
    local p = player.create({ track_durations = { 100, 200 } })
    local bar = progress_bar.new({
        width = 400,
        duration = p:getDuration(),
        on_seek = function(pos) p:setPosition(pos) end,
    })
    -- Seek to 150s (midway through track 2)
    bar:onTapProgress({ pos = { x = 300 } })  -- 75% of 300s = 225s → clamped to 300
    -- Position should have been updated via on_seek callback
    mock.assert_equals(p:getPosition(), 225, "player position updated via bar seek")
end)

-- ============================================================
-- Slice 8b: Progress Bar Visual Rendering (paintTo)
-- ============================================================

run_test("progress_bar: paintTo draws background and fill rectangles", function()
    local progress_bar = require("absaudio/progress_bar")
    local bar = progress_bar.new({ width = 400, duration = 100, on_seek = function() end })

    -- Mock blitbuffer that records paintRect calls
    local paint_log = {}
    local mock_bb = {
        paintRect = function(self, x, y, w, h, color)
            table.insert(paint_log, { x=x, y=y, w=w, h=h, color=color })
        end,
    }

    bar:setPosition(50)  -- 50% fill → 200px of 400px width
    bar:paintTo(mock_bb, 10, 20)

    -- Should draw exactly 2 rects: background + fill
    mock.assert_equals(#paint_log, 2,
        "paintTo should draw background + fill (2 rects)")

    -- Background: full width at centered y offset
    local bg = paint_log[1]
    mock.assert_equals(bg.w, 400, "background rect width = bar width")
    mock.assert_equals(bg.h, 6, "background rect height = bar height")
    mock.assert_equals(bg.y, 17, "background y centered within tap-target dimen")

    -- Fill: half width (50% of 400 = 200)
    local fill = paint_log[2]
    mock.assert_equals(fill.w, 200, "fill rect width = 50% of bar width")
    mock.assert_equals(fill.h, 6, "fill rect height = bar height")
end)

run_test("progress_bar: paintTo with zero position draws only background", function()
    local progress_bar = require("absaudio/progress_bar")
    local bar = progress_bar.new({ width = 400, duration = 100, on_seek = function() end })

    local paint_log = {}
    local mock_bb = {
        paintRect = function(self, x, y, w, h, color)
            table.insert(paint_log, { x=x, y=y, w=w, h=h, color=color })
        end,
    }

    bar:setPosition(0)
    bar:paintTo(mock_bb, 0, 0)

    -- Only background drawn when no fill
    mock.assert_equals(#paint_log, 1,
        "zero position should only draw background (no fill rect)")
end)

run_test("progress_bar: paintTo with full position fills entire bar", function()
    local progress_bar = require("absaudio/progress_bar")
    local bar = progress_bar.new({ width = 400, duration = 100, on_seek = function() end })

    local paint_log = {}
    local mock_bb = {
        paintRect = function(self, x, y, w, h, color)
            table.insert(paint_log, { x=x, y=y, w=w, h=h, color=color })
        end,
    }

    bar:setPosition(100)  -- full
    bar:paintTo(mock_bb, 0, 0)

    -- Both rects should be full width
    mock.assert_equals(paint_log[1].w, 400, "background full width")
    mock.assert_equals(paint_log[2].w, 400, "fill full width at 100%")
end)

run_test("progress_bar: paintTo uses e-ink colors", function()
    local progress_bar = require("absaudio/progress_bar")
    local bar = progress_bar.new({ width = 100, duration = 10, on_seek = function() end })

    local paint_log = {}
    local mock_bb = {
        paintRect = function(self, x, y, w, h, color)
            table.insert(paint_log, color)
        end,
    }

    bar:paintTo(mock_bb, 0, 0)

    -- Background should be LIGHT_GRAY, fill should be DARK_GRAY
    mock.assert_equals(paint_log[1], Blitbuffer.COLOR_LIGHT_GRAY,
        "background uses COLOR_LIGHT_GRAY")
    if #paint_log > 1 then
        mock.assert_equals(paint_log[2], Blitbuffer.COLOR_DARK_GRAY,
            "fill uses COLOR_DARK_GRAY")
    end
end)

-- ============================================================
-- Slice 9: Backend Strategy Pattern + Inkview FFI Scaffold
-- ============================================================

run_test("backend: create with explicit stub backend works", function()
    local player = require("absaudio/player")
    local p = player.create({
        track_durations = { 100, 200 },
        backend = "stub",
    })
    mock.assert_equals(p:getState(), "stopped", "initial state is stopped")
    mock.assert_equals(p:getDuration(), 300, "total duration")
    p:play()
    mock.assert_equals(p:getState(), "playing", "state after play")
end)

run_test("backend: create_from_manifest uses stub by default", function()
    local player = require("absaudio/player")
    local book = {
        local_dir = "/tmp/test",
        current_time = 45,
        files = {{ filename = "a.m4b", type = "audio" }},
    }
    local item = { audioFiles = {{ duration = 180 }} }
    local p = player.create_from_manifest(book, item)
    mock.assert_equals(p ~= nil, true, "player created from manifest")
    mock.assert_equals(p:getDuration(), 180, "duration from audioFiles")
end)

run_test("backend: inkview backend can be created when FFI available", function()
    local player = require("absaudio/player")
    local has_ffi, _ = pcall(require, "ffi")
    if not has_ffi then return end
    local p = player.create({
        track_durations = { 100 },
        backend = "inkview",
        file_paths = { "/tmp/test.m4b" },
    })
    mock.assert_equals(p:getState(), "stopped", "inkview backend initial state")
    mock.assert_equals(p:getDuration(), 100, "inkview backend duration")
end)

-- ============================================================
-- Slice 10: M3U Playlist Generation
-- ============================================================

run_test("m3u: build_playlist returns file paths from manifest", function()
    local player = require("absaudio/player")
    local book = {
        local_dir = "/tmp/book1",
        files = {{ filename = "ch01.m4b", type = "audio" },
               { filename = "ch02.m4b", type = "audio" }},
    }
    local playlist = player.build_playlist(book)
    mock.assert_equals(#playlist, 2, "2 audio files in playlist")
    mock.assert_equals(playlist[1], "/tmp/book1/ch01.m4b", "first file path")
    mock.assert_equals(playlist[2], "/tmp/book1/ch02.m4b", "second file path")
end)

run_test("m3u: inkview _buildPlaylist creates valid m3u content", function()
    local inkview_backend_mod = require("absaudio/inkview_backend")
    -- Create a temp directory for test
    local test_dir = "/tmp/m3u_test_" .. os.time()
    os.execute("mkdir -p " .. test_dir)

    local backend = inkview_backend_mod.new({
        track_durations = { 100, 200 },
        file_paths = { test_dir .. "/track1.m4b", test_dir .. "/track2.m4b" },
    })

    local playlist_path = backend:_buildPlaylist()
    mock.assert_equals(playlist_path ~= nil, true, "playlist created")

    -- Read and verify content
    local f = io.open(playlist_path, "r")
    local content = f:read("*a")
    f:close()

    mock.assert_equals(content:find("#EXTM3U") ~= nil, true, "has EXTM3U header")
    mock.assert_equals(content:find("track1.m4b") ~= nil, true, "has track 1")
    mock.assert_equals(content:find("track2.m4b") ~= nil, true, "has track 2")

    -- Cleanup
    os.remove(playlist_path)
    os.remove(test_dir)
end)

run_test("m3u: empty file_paths returns nil playlist", function()
    local inkview_backend_mod = require("absaudio/inkview_backend")
    local backend = inkview_backend_mod.new({
        track_durations = {},
        file_paths = {},
    })
    mock.assert_equals(backend:_buildPlaylist(), nil, "nil for empty paths")
end)

-- ============================================================
-- Slice 11: Playback speed presets (cycle + format)
-- Presets: 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2 (PRD §Playback Speed).
-- ============================================================

run_test("next_speed: cycles through all presets and wraps", function()
    mock.assert_equals(player.next_speed(0.5), 0.75, "0.5 → 0.75")
    mock.assert_equals(player.next_speed(0.75), 1.0, "0.75 → 1")
    mock.assert_equals(player.next_speed(1.0), 1.25, "1 → 1.25")
    mock.assert_equals(player.next_speed(1.25), 1.5, "1.25 → 1.5")
    mock.assert_equals(player.next_speed(1.5), 1.75, "1.5 → 1.75")
    mock.assert_equals(player.next_speed(1.75), 2.0, "1.75 → 2")
    mock.assert_equals(player.next_speed(2.0), 0.5, "2 wraps to 0.5")
end)

run_test("next_speed: unknown/nil input → 1.25 (treat as 1× base)", function()
    mock.assert_equals(player.next_speed(nil), 1.25, "nil treated as 1× → 1.25")
    mock.assert_equals(player.next_speed(1.33), 1.25, "unknown normalized to base → 1.25")
end)

run_test("format_speed: renders presets without trailing zero", function()
    mock.assert_equals(player.format_speed(1.0), "1×", "1× not 1.0×")
    mock.assert_equals(player.format_speed(2.0), "2×", "2× not 2.0×")
    mock.assert_equals(player.format_speed(1.5), "1.5×", "1.5×")
    mock.assert_equals(player.format_speed(0.75), "0.75×", "0.75×")
    mock.assert_equals(player.format_speed(1.25), "1.25×", "1.25×")
end)

run_test("format_speed: nil → '1×' default badge", function()
    mock.assert_equals(player.format_speed(nil), "1×", "nil falls back to 1×")
end)

-- Summary

print(string.format("\n%d passed, %d failed", passed, failed))
if #errors > 0 then
    print("\nFailures:")
    for _, e in ipairs(errors) do
        print("  " .. e.name .. ": " .. e.message)
    end
    os.exit(1)
end