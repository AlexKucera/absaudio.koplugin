-- Chapter navigator tests
-- Pure-logic position ↔ chapter mapping for absaudio.koplugin.
--
-- Covers acceptance criteria from issue #7:
--   current chapter for any global position; next/prev chapter;
--   seek-to-chapter-start; boundary behavior (exactly at start/end,
--   beyond last chapter, single-chapter book, empty chapters array).
--
-- Run with: luajit spec/test_chapter_navigator.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local nav = require("absaudio/chapter_navigator")
local mock = require("spec/test_helper")

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

-- Three contiguous chapters covering a full 2400s book.
--   ch1: [0,   600)   "Intro"
--   ch2: [600, 1500)  "Chapter 2: The Wildfire"
--   ch3: [1500, 2400) "Chapter 3"
local CHAPTERS = {
    { id = 0, start = 0,    ["end"] = 600,  title = "Intro" },
    { id = 1, start = 600,  ["end"] = 1500, title = "Chapter 2: The Wildfire" },
    { id = 2, start = 1500, ["end"] = 2400, title = "Chapter 3" },
}

-- ============================================================
-- Slice 1: current() — basic + mid-chapter lookup
-- Scenario (US 27): given a global position, the navigator returns
-- the chapter the listener is currently in.
-- ============================================================

run_test("current: position 0 → first chapter", function()
    local idx, ch = nav.current(0, CHAPTERS)
    mock.assert_equals(idx, 1, "index 1")
    mock.assert_equals(ch.title, "Intro", "Intro chapter")
end)

run_test("current: mid-first-chapter → chapter 1", function()
    local idx, ch = nav.current(300, CHAPTERS)
    mock.assert_equals(idx, 1, "still chapter 1")
    mock.assert_equals(ch.title, "Intro", "Intro chapter")
end)

run_test("current: mid-second-chapter → chapter 2", function()

-- ============================================================
-- Slice 2: current() — boundary behavior (acceptance criteria)
-- exactly at chapter start/end, beyond last, negative,
-- single-chapter book, empty chapters array.
-- Convention: half-open [start, end) → a boundary belongs to the
-- LATER chapter.
-- ============================================================

run_test("current: exact chapter start (600) → LATER chapter", function()
    local idx = nav.current(600, CHAPTERS)
    mock.assert_equals(idx, 2, "boundary belongs to the later chapter")
end)

run_test("current: exact chapter end (1500) → LATER chapter", function()
    local idx = nav.current(1500, CHAPTERS)
    mock.assert_equals(idx, 3, "ch2 end == ch3 start → chapter 3")
end)

run_test("current: position beyond last chapter → clamps to last", function()
    local idx, ch = nav.current(3000, CHAPTERS)
    mock.assert_equals(idx, 3, "clamped to last chapter")
    mock.assert_equals(ch.title, "Chapter 3", "last chapter returned")
end)

run_test("current: exact last-chapter end → clamps to last (no chapter 4)", function()
    local idx = nav.current(2400, CHAPTERS)
    mock.assert_equals(idx, 3, "end of book is still the last chapter")
end)

run_test("current: negative position → first chapter", function()
    local idx = nav.current(-10, CHAPTERS)
    mock.assert_equals(idx, 1, "clamped to first chapter")
end)

run_test("current: single-chapter book, mid → chapter 1", function()
    local one = { { id = 0, start = 0, ["end"] = 3600, title = "Whole Book" } }
    local idx, ch = nav.current(1800, one)
    mock.assert_equals(idx, 1, "only chapter")
    mock.assert_equals(ch.title, "Whole Book", "title returned")
end)

run_test("current: empty chapters array → (0, nil)", function()
    local idx, ch = nav.current(100, {})
    mock.assert_equals(idx, 0, "no chapters → index 0")
    mock.assert_equals(ch, nil, "no chapter table")
end)

run_test("current: nil chapters → (0, nil)", function()
    local idx, ch = nav.current(100, nil)
    mock.assert_equals(idx, 0, "nil chapters → index 0")
    mock.assert_equals(ch, nil, "no chapter table")
end)

-- ============================================================
-- Slice 3: next() — next chapter after the current one
-- Scenario (US 29): tapping next-chapter seeks to the next
-- chapter's start. At the last chapter there is no next.
-- ============================================================

run_test("next: from chapter 1 → chapter 2", function()
    local idx, ch = nav.next(300, CHAPTERS)
    mock.assert_equals(idx, 2, "next index")
    mock.assert_equals(ch.title, "Chapter 2: The Wildfire", "next chapter")
end)

run_test("next: from chapter 2 → chapter 3", function()
    local idx, ch = nav.next(800, CHAPTERS)
    mock.assert_equals(idx, 3, "next index")
    mock.assert_equals(ch.title, "Chapter 3", "next chapter")
end)

run_test("next: at last chapter → (nil, nil)", function()
    local idx, ch = nav.next(2000, CHAPTERS)
    mock.assert_equals(idx, nil, "no next chapter at last")
    mock.assert_equals(ch, nil, "no chapter table")
end)

run_test("next: beyond last chapter → (nil, nil)", function()
    local idx, ch = nav.next(3000, CHAPTERS)
    mock.assert_equals(idx, nil, "no next beyond last")
    mock.assert_equals(ch, nil, "no chapter table")
end)

run_test("next: empty chapters → (nil, nil)", function()
    local idx, ch = nav.next(100, {})
    mock.assert_equals(idx, nil, "no chapters")
    mock.assert_equals(ch, nil, "no chapter table")
end)

-- ============================================================
-- Slice 4: previous() — smart restart (chosen UX)
-- Deep into a chapter (>threshold) → restart the CURRENT chapter.
-- Near the start (<=threshold) → jump to the PREVIOUS chapter,
-- clamped to the first. Default threshold 10s.
-- ============================================================

run_test("previous: deep in chapter 2 → restart current (ch2)", function()
    local idx, ch = nav.previous(800, CHAPTERS)  -- elapsed 200s > 10
    mock.assert_equals(idx, 2, "restarts current chapter")
    mock.assert_equals(ch.title, "Chapter 2: The Wildfire")
end)

run_test("previous: near start of chapter 2 → jump to ch1", function()
    local idx, ch = nav.previous(605, CHAPTERS)  -- elapsed 5s < 10
    mock.assert_equals(idx, 1, "jumps to previous chapter")
    mock.assert_equals(ch.title, "Intro")
end)

run_test("previous: deep in first chapter → restart first (clamp)", function()
    local idx = nav.previous(500, CHAPTERS)  -- elapsed 500s, but no prior chapter
    mock.assert_equals(idx, 1, "restarts first chapter")
end)

run_test("previous: near start of first chapter → clamp to first", function()
    local idx = nav.previous(3, CHAPTERS)  -- elapsed 3s, first chapter
    mock.assert_equals(idx, 1, "stays on first chapter")
end)

run_test("previous: at last-chapter end → restart last", function()
    local idx = nav.previous(2400, CHAPTERS)  -- clamped last, elapsed large
    mock.assert_equals(idx, 3, "restarts last chapter")
end)

run_test("previous: custom threshold honoured", function()
    -- elapsed 20s; with threshold 100 → treat as 'near start' → previous chapter
    local idx = nav.previous(620, CHAPTERS, { threshold = 100 })
    mock.assert_equals(idx, 1, "large threshold → previous chapter")
    -- same position with default threshold 10 → elapsed 20 > 10 → restart
    local idx2 = nav.previous(620, CHAPTERS)
    mock.assert_equals(idx2, 2, "default threshold → restart current")
end)

run_test("previous: empty chapters → (nil, nil)", function()
    local idx, ch = nav.previous(100, {})
    mock.assert_equals(idx, nil)
    mock.assert_equals(ch, nil)
end)

-- ============================================================
-- Slice 5: chapter_start() — seek target for a chapter index
-- Scenario (US 28): tapping a chapter in the list seeks to that
-- chapter's start position. Clamps out-of-range indices.
-- ============================================================

run_test("chapter_start: index 1 → 0", function()
    mock.assert_equals(nav.chapter_start(1, CHAPTERS), 0, "first chapter starts at 0")
end)

run_test("chapter_start: index 2 → 600", function()
    mock.assert_equals(nav.chapter_start(2, CHAPTERS), 600, "second chapter start")
end)

run_test("chapter_start: index 3 → 1500", function()
    mock.assert_equals(nav.chapter_start(3, CHAPTERS), 1500, "third chapter start")
end)

run_test("chapter_start: index 0 → clamps to first (0)", function()
    mock.assert_equals(nav.chapter_start(0, CHAPTERS), 0, "index 0 clamps to first")
end)

run_test("chapter_start: index beyond last → clamps to last start", function()
    mock.assert_equals(nav.chapter_start(99, CHAPTERS), 1500, "clamps to last chapter start")
end)

run_test("chapter_start: empty/nil chapters → 0", function()
    mock.assert_equals(nav.chapter_start(1, {}), 0, "no chapters → 0")
    mock.assert_equals(nav.chapter_start(1, nil), 0, "nil chapters → 0")
end)

run_test("integration: prev→chapter_start→seek→current lands in target chapter", function()
    -- Start in chapter 3 at 2000s; prev (elapsed 500 > 10) restarts chapter 3;
    -- seeking to its start keeps us in chapter 3.
    local target_idx = nav.previous(2000, CHAPTERS)
    local seek = nav.chapter_start(target_idx, CHAPTERS)
    local landed = nav.current(seek, CHAPTERS)
    mock.assert_equals(landed, target_idx, "after seek we are in the target chapter")

    -- Near the start of chapter 2: prev → chapter 1; seek to its start (0).
    local idx2 = nav.previous(605, CHAPTERS)
    mock.assert_equals(nav.chapter_start(idx2, CHAPTERS), 0, "prev near-start → ch1 start")
end)
    local idx, ch = nav.current(800, CHAPTERS)
    mock.assert_equals(idx, 2, "chapter 2")
    mock.assert_equals(ch.title, "Chapter 2: The Wildfire", "title returned")
end)

-- ============================================================
-- Summary
-- ============================================================

print(string.format("\n%d passed, %d failed", passed, failed))
if #errors > 0 then
    print("\nFailures:")
    for _, e in ipairs(errors) do
        print("  " .. e.name .. ": " .. tostring(e.err))
    end
    os.exit(1)
end
