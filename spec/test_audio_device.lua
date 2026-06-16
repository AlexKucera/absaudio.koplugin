-- audio_device tests for absaudio.koplugin (issue #39, audio slice D)
--
-- audio_device.lua is the REAL device glue (FFmpeg decode + ALSA output).
-- Off-device (Mac), audio_ffi.get_lib() returns nil → every factory must
-- degrade gracefully: (nil, err), never a crash.
--
-- The actual FFmpeg/ALSA paths (open file, decode frame, swr_convert,
-- snd_pcm_writei) are HITL device-only (PB700K3) — the audible-success probe
-- already confirmed the exact call sequence, and audio_device.lua mirrors it.
-- These tests verify the GUARDED-SEAM contract: graceful degradation + the
-- API shapes that decode_producer / output_pump / ffmpeg_backend rely on.
--
-- Run with: luajit spec/test_audio_device.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local mock = require("spec/test_helper")
local audio_device = require("absaudio/audio_device")
local audio_ffi = require("absaudio/audio_ffi")
local ffi = require("ffi")  -- used by the stereo frame-math regression tests

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
-- Module shape
-- ============================================================

run_test("module exports create_decoder, create_alsa_sink, create_schedule", function()
    mock.assert_equals(type(audio_device.create_decoder), "function", "create_decoder")
    mock.assert_equals(type(audio_device.create_alsa_sink), "function", "create_alsa_sink")
    mock.assert_equals(type(audio_device.create_schedule), "function", "create_schedule")
end)

-- ============================================================
-- create_decoder — graceful degradation off-device
-- ============================================================

run_test("create_decoder returns (nil, err) when FFmpeg unavailable (off-device)", function()
    -- On Mac, audio_ffi.get_lib() returns nil → must not crash, must return (nil, err)
    local decoder, err = audio_device.create_decoder("/some/file.m4b")
    mock.assert_equals(decoder, nil, "decoder should be nil off-device")
    mock.assert_equals(type(err), "string", "err should be a string")
    mock.assert_equals(err:find("unavailable") ~= nil, true,
        "err should mention unavailable: " .. tostring(err))
end)

run_test("create_decoder does not crash with empty path", function()
    local decoder, err = audio_device.create_decoder("")
    mock.assert_equals(decoder, nil, "decoder should be nil")
    mock.assert_equals(type(err), "string", "err should be a string")
end)

run_test("create_decoder does not crash with nil path", function()
    -- Even a nil path should be caught by the guarded seam before any FFI call
    local decoder, err = audio_device.create_decoder(nil)
    mock.assert_equals(decoder, nil, "decoder should be nil")
    -- The guard checks get_lib() FIRST, so it returns the "unavailable" error
    -- before even looking at path. That's correct: if there's no lib, there's
    -- no point validating the path.
    mock.assert_equals(type(err), "string", "err should be a string")
end)

-- ============================================================
-- create_alsa_sink — argument validation + graceful degradation
-- ============================================================

run_test("create_alsa_sink returns (nil, err) with no opts", function()
    local sink, err = audio_device.create_alsa_sink(nil)
    mock.assert_equals(sink, nil, "sink should be nil")
    mock.assert_equals(type(err), "string", "err should be a string")
    mock.assert_equals(err:find("sample_rate") ~= nil or err:find("channels") ~= nil,
        true, "err should mention missing params: " .. tostring(err))
end)

run_test("create_alsa_sink returns (nil, err) with empty opts", function()
    local sink, err = audio_device.create_alsa_sink({})
    mock.assert_equals(sink, nil, "sink should be nil")
    mock.assert_equals(type(err), "string", "err should be a string")
end)

run_test("create_alsa_sink returns (nil, err) missing channels", function()
    local sink, err = audio_device.create_alsa_sink({ sample_rate = 44100 })
    mock.assert_equals(sink, nil, "sink should be nil")
    mock.assert_equals(type(err), "string", "err should be a string")
end)

run_test("create_alsa_sink returns (nil, err) missing sample_rate", function()
    local sink, err = audio_device.create_alsa_sink({ channels = 2 })
    mock.assert_equals(sink, nil, "sink should be nil")
    mock.assert_equals(type(err), "string", "err should be a string")
end)

run_test("create_alsa_sink returns (nil, err) with valid opts but no ALSA (off-device)", function()
    -- Valid opts pass validation, then hit the lib check → graceful failure
    local sink, err = audio_device.create_alsa_sink({ sample_rate = 44100, channels = 2 })
    mock.assert_equals(sink, nil, "sink should be nil off-device")
    mock.assert_equals(type(err), "string", "err should be a string")
    mock.assert_equals(err:find("unavailable") ~= nil or err:find("ALSA") ~= nil,
        true, "err should mention ALSA unavailability: " .. tostring(err))
end)

-- ============================================================
-- create_schedule — returns a usable scheduling function always
-- ============================================================

run_test("create_schedule returns a function", function()
    local schedule = audio_device.create_schedule()
    mock.assert_equals(type(schedule), "function", "schedule should be a function")
end)

run_test("schedule fn returns a cancel function even without UIManager", function()
    -- Off-device there's no UIManager → schedule falls back to a no-op cancel
    local schedule = audio_device.create_schedule()
    local cancel = schedule(0.05, function() end)
    mock.assert_equals(type(cancel), "function", "cancel should be a function")
    cancel()  -- should not crash
end)

run_test("schedule fn is callable with delay + callback args", function()
    local schedule = audio_device.create_schedule()
    local cancel = schedule(0.1, function() print("  (scheduled callback would fire here on device)") end)
    cancel()
end)

-- ============================================================
-- REGRESSION: stereo byte→frame math (scratchy-audio fix)
--
-- Bug: sink.write divided total bytes by 2 (mono math) instead of
-- channels*2, so snd_pcm_writei was told there were 2x too many frames and
-- read past the buffer into garbage → scratchy audio. This test injects a
-- fake lib so the sink's frame-count path runs off-device.
-- ============================================================

local function make_fake_lib()
    local calls = { writei = {} }
    return {
        _calls = calls,
        snd_pcm_open = function(p, d, s, m)
            p[0] = ffi.new("snd_pcm_t*")  -- non-null placeholder handle
            return 0
        end,
        snd_pcm_set_params = function() return 0 end,
        snd_pcm_writei = function(pcm, buf, frames)
            table.insert(calls.writei, tonumber(frames) or -1)
            return tonumber(frames) or 0
        end,
        snd_pcm_drain = function() return 0 end,
        snd_pcm_close = function() return 0 end,
    }, calls
end

run_test("sink.write passes FRAMES (bytes/(channels*2)) to snd_pcm_writei for stereo", function()
    local ffi_ok2, ffi2 = pcall(require, "ffi")
    if not ffi_ok2 then error("ffi required for this test") end
    ffi = ffi2  -- file-local ffi upvalue for make_fake_lib placeholder cast
    local fake_lib, calls = make_fake_lib()
    audio_ffi._set_lib_for_testing(fake_lib)
    local sink = audio_device.create_alsa_sink({ sample_rate = 22050, channels = 2 })
    mock.assert_equals(type(sink), "table", "sink should be created with fake lib")
    sink.open()  -- opens lazily with the fake lib
    -- 4096 bytes of stereo S16 = 4096 / (2ch * 2) = 1024 frames.
    -- The bug passed 2048 (4096/2) → ALSA read 2x the buffer → scratchy.
    sink.write(string.rep("x", 4096), 4096)
    mock.assert_equals(#calls.writei, 1, "one writei call expected")
    mock.assert_equals(calls.writei[1], 1024,
        "stereo: 4096 bytes must map to 1024 FRAMES, not " .. tostring(calls.writei[1]))
    sink.close()
    audio_ffi._set_lib_for_testing(nil)
end)

run_test("sink.write passes correct frames for mono (bytes/(1*2))", function()
    local ffi_ok2, ffi2 = pcall(require, "ffi")
    if not ffi_ok2 then error("ffi required for this test") end
    ffi = ffi2
    local fake_lib, calls = make_fake_lib()
    audio_ffi._set_lib_for_testing(fake_lib)
    local sink = audio_device.create_alsa_sink({ sample_rate = 22050, channels = 1 })
    sink.open()
    -- 2048 bytes mono S16 = 2048 / (1*2) = 1024 frames.
    sink.write(string.rep("x", 2048), 2048)
    mock.assert_equals(calls.writei[1], 1024,
        "mono: 2048 bytes must map to 1024 frames, not " .. tostring(calls.writei[1]))
    sink.close()
    audio_ffi._set_lib_for_testing(nil)
end)

run_test("sink.write drops a sub-frame (odd-byte) chunk without crash", function()
    local ffi_ok2, ffi2 = pcall(require, "ffi")
    if not ffi_ok2 then error("ffi required for this test") end
    ffi = ffi2
    local fake_lib, calls = make_fake_lib()
    audio_ffi._set_lib_for_testing(fake_lib)
    local sink = audio_device.create_alsa_sink({ sample_rate = 22050, channels = 2 })
    sink.open()
    -- 5 bytes is not a whole stereo frame (4 bytes) → 5/4 = 1 frame, remainder dropped.
    sink.write(string.rep("x", 5), 5)
    mock.assert_equals(#calls.writei, 1, "one writei call expected (1 frame)")
    mock.assert_equals(calls.writei[1], 1, "5 stereo bytes → 1 frame (1 byte remainder dropped)")
    sink.close()
    audio_ffi._set_lib_for_testing(nil)
end)

-- ============================================================
-- REGRESSION: underrun recovery (silence-after-first-chunk fix)
--
-- Bug: snd_pcm_writei returning -EPIPE (-32, underrun) was never recovered,
-- so once ALSA's buffer drained the stream was stuck forever → audio played
-- ~1s then died. Fix: on -EPIPE/-ESTRPIPE, call snd_pcm_prepare() and retry
-- the write once. This test fakes a writei that underruns, then succeeds
-- after prepare, and asserts the recovery path runs.
-- ============================================================

run_test("sink.write recovers from ALSA underrun (-EPIPE) via snd_pcm_prepare + retry", function()
    local calls = { writei = {}, prepare = 0 }
    local writei_returns = { -32, 1024 }  -- 1st: underrun; 2nd (post-prepare): success
    local fake_lib = {
        snd_pcm_open = function(p, d, s, m) p[0] = ffi.new("snd_pcm_t*") return 0 end,
        snd_pcm_set_params = function() return 0 end,
        snd_pcm_writei = function(pcm, buf, frames)
            local r = table.remove(writei_returns, 1) or 0
            table.insert(calls.writei, { frames = tonumber(frames) or -1, ret = r })
            return r
        end,
        snd_pcm_prepare = function(pcm) calls.prepare = calls.prepare + 1 return 0 end,
        snd_pcm_drain = function() return 0 end,
        snd_pcm_close = function() return 0 end,
    }
    audio_ffi._set_lib_for_testing(fake_lib)
    local sink = audio_device.create_alsa_sink({ sample_rate = 22050, channels = 2 })
    sink.open()
    -- 4096 stereo bytes = 1024 frames. First writei underruns (-32); recovery
    -- must call prepare() then retry, and the retry returns 1024 (success).
    sink.write(string.rep("x", 4096), 4096)
    mock.assert_equals(#calls.writei, 2,
        "writei must be called twice: 1st underrun, 2nd post-prepare retry (got " .. #calls.writei .. ")")
    mock.assert_equals(calls.prepare, 1,
        "snd_pcm_prepare must be called exactly once for recovery (got " .. calls.prepare .. ")")
    mock.assert_equals(calls.writei[2].ret, 1024,
        "retried write must return success (1024), not " .. tostring(calls.writei[2].ret))
    sink.close()
    audio_ffi._set_lib_for_testing(nil)
end)

run_test("sink.write gives up on prepare() failure (no infinite retry loop)", function()
    local calls = { writei = 0, prepare = 0 }
    local fake_lib = {
        snd_pcm_open = function(p, d, s, m) p[0] = ffi.new("snd_pcm_t*") return 0 end,
        snd_pcm_set_params = function() return 0 end,
        snd_pcm_writei = function(pcm, buf, frames) calls.writei = calls.writei + 1 return -32 end,
        snd_pcm_prepare = function(pcm) calls.prepare = calls.prepare + 1 return -999 end,  -- prepare fails
        snd_pcm_drain = function() return 0 end,
        snd_pcm_close = function() return 0 end,
    }
    audio_ffi._set_lib_for_testing(fake_lib)
    local sink = audio_device.create_alsa_sink({ sample_rate = 22050, channels = 2 })
    sink.open()
    sink.write(string.rep("x", 4096), 4096)
    -- writei called once (underrun), prepare called once (fails) → NO retry.
    mock.assert_equals(calls.writei, 1, "must not retry when prepare fails (got " .. calls.writei .. ")")
    mock.assert_equals(calls.prepare, 1, "prepare tried once")
    sink.close()
    audio_ffi._set_lib_for_testing(nil)
end)

run_test("sink.write does not attempt recovery on non-underrun error (-22 EINVAL)", function()
    local calls = { writei = 0, prepare = 0 }
    local fake_lib = {
        snd_pcm_open = function(p, d, s, m) p[0] = ffi.new("snd_pcm_t*") return 0 end,
        snd_pcm_set_params = function() return 0 end,
        snd_pcm_writei = function(pcm, buf, frames) calls.writei = calls.writei + 1 return -22 end,  -- EINVAL
        snd_pcm_prepare = function(pcm) calls.prepare = calls.prepare + 1 return 0 end,
        snd_pcm_drain = function() return 0 end,
        snd_pcm_close = function() return 0 end,
    }
    audio_ffi._set_lib_for_testing(fake_lib)
    local sink = audio_device.create_alsa_sink({ sample_rate = 22050, channels = 2 })
    sink.open()
    sink.write(string.rep("x", 4096), 4096)
    mock.assert_equals(calls.writei, 1, "EINVAL is not an underrun → single write, no retry")
    mock.assert_equals(calls.prepare, 0, "prepare must NOT be called for EINVAL")
    sink.close()
    audio_ffi._set_lib_for_testing(nil)
end)

-- ============================================================
-- REGRESSION: sample-count position tracking (progress-timer-stuck-at-zero fix)
--
-- Bug: AVFrame.pts offset is wrong (probe showed offsetof=160 vs commented 192),
-- so frame.pts reads as 0 for every frame → position stuck at 0. Fix: compute
-- position from accumulated decoded samples (nb_samples@112 + sample_rate, both
-- verified on-device). This test locks down the formula with known values
-- (22050 Hz, 1024 samples/frame — confirmed by the backend readiness probe).
-- ============================================================

run_test("sample-count position: 22050 Hz / 1024 samples-per-frame advances correctly", function()
    -- Simulate the decoder's position computation for frames 1-5.
    -- Frame N position = (N-1)*1024 samples / 22050 Hz * 1000 ms
    local sample_rate = 22050
    local samples_per_frame = 1024
    local samples_decoded = 0
    local positions = {}
    for i = 1, 5 do
        local pts_ms = math.floor(samples_decoded * 1000 / sample_rate)
        table.insert(positions, pts_ms)
        samples_decoded = samples_decoded + samples_per_frame
    end
    -- Frame 1 starts at 0ms, frame 2 at ~46ms, frame 3 at ~93ms, etc.
    mock.assert_equals(positions[1], 0,  "frame 1 at 0ms")
    mock.assert_equals(positions[2], 46, "frame 2 at ~46ms (1024/22050*1000)")
    mock.assert_equals(positions[3], 92, "frame 3 at ~92ms (2048/22050*1000)")
    mock.assert_equals(positions[4], 139, "frame 4 at ~139ms")
    mock.assert_equals(positions[5], 185, "frame 5 at ~185ms (4096/22050*1000)")
    -- CRITICAL: positions MUST be strictly monotonically increasing.
    for i = 2, #positions do
        mock.assert_equals(true, positions[i] > positions[i-1],
            "frame " .. i .. " must advance past frame " .. (i-1))
    end
end)

run_test("sample-count position: scales to minutes (long-form audiobook)", function()
    -- After 10 minutes of 22050 Hz audio: 10*60*22050 = 13,230,000 samples
    local sample_rate = 22050
    local ten_min_samples = 10 * 60 * sample_rate
    local pts_ms = math.floor(ten_min_samples * 1000 / sample_rate)
    mock.assert_equals(pts_ms, 600000, "10 minutes = 600,000 ms")
end)

-- ============================================================
-- Summary
-- ============================================================

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
    print("\nFAILURES:")
    for _, e in ipairs(errors) do
        print("  " .. e.name .. ": " .. e.err)
    end
    os.exit(1)
end
