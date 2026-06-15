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
