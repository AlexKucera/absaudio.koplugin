-- Chapter navigator for absaudio.koplugin
-- Pure logic (no FFI, no KOReader dependencies, no I/O).
-- Maps a global playback position (seconds from book start) to ABS chapters.
--
-- ABS chapter shape (from /api/items/:id media.chapters):
--   { id = number, start = number (seconds), end = number (seconds), title = string }
-- Chapters are contiguous and cover the book's full duration on a single
-- GLOBAL timeline (not per-track).
--
-- Boundary convention: a chapter covers the half-open interval [start, end).
-- A position exactly at a boundary (chapter[i].end == chapter[i+1].start)
-- belongs to the LATER chapter. This matches "I just reached chapter N".
--
-- Public API:
--   nav.current(global_seconds, chapters)        → (index, chapter)
--   nav.next(global_seconds, chapters)           → (index, chapter) | (nil, nil)
--   nav.previous(global_seconds, chapters, opts) → (index, chapter) | (nil, nil)
--   nav.chapter_start(index, chapters)           → seconds (seek target)
-- All return (0, nil) / 0 for empty/missing chapters.

local chapter_navigator = {}

------------------------------------------------------------------------
-- Current chapter for a global position.
--
-- @param global_seconds  number   position from book start (seconds)
-- @param chapters        array    ABS chapters: {id, start, end, title}
-- @return number index           1-based (0 if no chapters)
-- @return table|nil chapter      the chapter table (nil if no chapters)
------------------------------------------------------------------------
function chapter_navigator.current(global_seconds, chapters)
    if not chapters or #chapters == 0 then
        return 0, nil
    end

    local pos = global_seconds
    if pos < 0 then pos = 0 end

    for i, ch in ipairs(chapters) do
        if pos < ch["end"] then
            return i, ch
        end
    end

    -- Beyond last chapter's end: clamp to last chapter.
    local last_idx = #chapters
    return last_idx, chapters[last_idx]
end

------------------------------------------------------------------------
-- Next chapter after the current position.
-- Returns (nil, nil) when already at/past the last chapter.
--
-- @return number|nil index, table|nil chapter
------------------------------------------------------------------------
function chapter_navigator.next(global_seconds, chapters)
    if not chapters or #chapters == 0 then
        return nil, nil
    end

    local cur_idx = chapter_navigator.current(global_seconds, chapters)
    if cur_idx >= #chapters then
        return nil, nil
    end
    return cur_idx + 1, chapters[cur_idx + 1]
end

------------------------------------------------------------------------
-- Previous chapter with smart-restart UX.
-- If the position is more than `opts.threshold` seconds into the
-- current chapter, restart the CURRENT chapter (return it). Otherwise
-- jump to the previous chapter, clamped to the first. Default threshold 10s.
--
-- @param opts table  optional: { threshold = number (seconds, default 10) }
-- @return number|nil index, table|nil chapter
------------------------------------------------------------------------
function chapter_navigator.previous(global_seconds, chapters, opts)
    if not chapters or #chapters == 0 then
        return nil, nil
    end

    opts = opts or {}
    local threshold = opts.threshold
    if threshold == nil then threshold = 10 end

    local cur_idx, cur = chapter_navigator.current(global_seconds, chapters)
    if cur_idx == 0 then
        return nil, nil
    end

    local pos = global_seconds
    if pos < 0 then pos = 0 end
    local elapsed = pos - (cur.start or 0)

    if elapsed > threshold then
        -- Restart the current chapter.
        return cur_idx, cur
    end

    -- Near the start: jump to previous chapter, clamped to first.
    if cur_idx <= 1 then
        return 1, chapters[1]
    end
    return cur_idx - 1, chapters[cur_idx - 1]
end

------------------------------------------------------------------------
-- Start position (seek target) of a chapter by 1-based index.
-- Clamps index to the valid range. Returns 0 for empty/missing chapters.
--
-- @param index    number  1-based chapter index (clamped to [1, #chapters])
-- @param chapters array
-- @return number  start position in seconds
------------------------------------------------------------------------
function chapter_navigator.chapter_start(index, chapters)
    if not chapters or #chapters == 0 then
        return 0
    end

    local idx = index
    if idx < 1 then idx = 1 end
    if idx > #chapters then idx = #chapters end
    return chapters[idx].start or 0
end

return chapter_navigator
