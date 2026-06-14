-- FFmpeg time-base math for absaudio.koplugin
-- Pure logic (no FFI, no KOReader dependencies, no I/O).
--
-- Converts between FFmpeg timestamp representations: a packet PTS (integer
-- count in a stream's time_base) and wall-clock seconds/milliseconds.
--
-- Time-base shape: a rational { num = numerator, den = denominator } where
-- one time-base unit = num/den seconds. Common examples:
--   { num = 1, den = 44100 }  — 44.1 kHz audio
--   { num = 1, den = 90000 }  — MPEG 90 kHz clock
--   { num = 1001, den = 24000 } — NTSC 24000/1001 fps
--   { num = 1, den = 1000 }   — milliseconds
--
-- Rounding convention: half-away-from-zero (FFmpeg AV_ROUND_NEAR_INF), so a
-- quotient of exactly 0.5 rounds up (and -0.5 rounds down to -1).
--
-- Public API:
--   rescale(value, from_tb, to_tb) → integer count in to_tb units
--   to_ms(pts, time_base)          → milliseconds
--   to_seconds(pts, time_base)     → seconds
--   ms_to_seconds(ms)              → seconds (float)
--   seconds_to_ms(sec)             → milliseconds (rounded)
--   clamp(value, max)              → value clamped to [0, max] (max nil → value)

local time_math = {}

------------------------------------------------------------------------
-- Core FFmpeg av_rescale_q arithmetic.
-- rescale(a, bq, cq) = av_rescale(a, bq.num*cq.den, bq.den*cq.num)
-- with AV_ROUND_NEAR_INF (half-away-from-zero).
--
-- @param value   number  integer count in from_tb units
-- @param from_tb table   source rational      {num, den}
-- @param to_tb   table   destination rational {num, den}
-- @return number         integer count in to_tb units
------------------------------------------------------------------------
function time_math.rescale(value, from_tb, to_tb)
    local num = from_tb.num * to_tb.den
    local den = from_tb.den * to_tb.num
    local scaled = value * num
    local r = math.floor(den / 2)   -- NEAR_INF rounding term
    if scaled >= 0 then
        return math.floor((scaled + r) / den)
    else
        return -math.floor((-scaled + r) / den)
    end
end

------------------------------------------------------------------------
-- Convert a packet PTS to milliseconds.
--
-- @param pts       number  presentation timestamp (count in time_base units)
-- @param time_base table   stream time-base {num, den}
-- @return number           milliseconds (integer)
------------------------------------------------------------------------
function time_math.to_ms(pts, time_base)
    return time_math.rescale(pts, time_base, { num = 1, den = 1000 })
end

------------------------------------------------------------------------
-- Convert a packet PTS to seconds.
--
-- @param pts       number  presentation timestamp (count in time_base units)
-- @param time_base table   stream time-base {num, den}
-- @return number           seconds (integer-valued from rescale)
------------------------------------------------------------------------
function time_math.to_seconds(pts, time_base)
    return time_math.rescale(pts, time_base, { num = 1, den = 1 })
end

------------------------------------------------------------------------
-- Convert milliseconds to seconds (float).
--
-- @param ms number  milliseconds
-- @return number     seconds (float)
------------------------------------------------------------------------
function time_math.ms_to_seconds(ms)
    return ms / 1000
end

------------------------------------------------------------------------
-- Convert seconds to milliseconds, rounded half up.
--
-- @param sec number  seconds
-- @return number     milliseconds (integer)
------------------------------------------------------------------------
function time_math.seconds_to_ms(sec)
    return math.floor(sec * 1000 + 0.5)
end

------------------------------------------------------------------------
-- Clamp a value to an upper bound.
-- Used to cap a computed position at the stream duration.
--
-- @param value number  the value to clamp
-- @param max   number|nil  upper bound (nil → no clamping)
-- @return number        value if max is nil, otherwise min(value, max)
------------------------------------------------------------------------
function time_math.clamp(value, max)
    if max ~= nil then
        return math.min(value, max)
    end
    return value
end

return time_math
