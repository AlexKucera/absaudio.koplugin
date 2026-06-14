-- Atempo filter-chain builder for absaudio.koplugin
-- Pure logic (no FFI, no KOReader dependencies, no I/O).
--
-- Builds FFmpeg `atempo` audio filter-chain strings for arbitrary playback
-- speeds. The `atempo` filter changes tempo (speed) without changing pitch.
--
-- Range rules:
--   A SINGLE atempo stage accepts tempo in [STAGE_MIN, STAGE_MAX] = [0.5, 2.0].
--   Speeds outside that range require CHAINING stages, where each stage's output
--   feeds the next: e.g. 4x = "atempo=2,atempo=2"; 0.25x = "atempo=0.5,atempo=0.5".
--
-- Number formatting: each stage value uses `%g` (matches player.format_speed),
-- so 1.0 -> "1", 1.5 -> "1.5", 0.75 -> "0.75", 2.0 -> "2".
--
-- Public API:
--   atempo.STAGE_MIN  = 0.5  (single-stage lower bound)
--   atempo.STAGE_MAX  = 2.0  (single-stage upper bound)
--   atempo.chain(speed) -> string   e.g. "atempo=1.5", "atempo=2,atempo=2"
--     Errors if speed is not a number or <= 0.

local atempo = {}

atempo.STAGE_MIN = 0.5
atempo.STAGE_MAX = 2.0

------------------------------------------------------------------------
-- Build a comma-separated FFmpeg atempo filter chain for a target speed.
-- Chains 2.0 stages (going up) or 0.5 stages (going down) until the
-- remainder lands within a single stage's [0.5, 2.0] range, then emits a
-- final stage for the remainder. The product of all stages equals the
-- input speed.
--
-- @param speed number  target playback speed multiplier (must be > 0)
-- @return string  filter chain, e.g. "atempo=1.5" or "atempo=2,atempo=2"
------------------------------------------------------------------------
function atempo.chain(speed)
    if type(speed) ~= "number" or speed <= 0 then
        error("atempo speed must be a positive number")
    end

    local stages = {}
    local remaining = speed

    while remaining > atempo.STAGE_MAX do
        stages[#stages + 1] = atempo.STAGE_MAX
        remaining = remaining / atempo.STAGE_MAX
    end

    while remaining < atempo.STAGE_MIN do
        stages[#stages + 1] = atempo.STAGE_MIN
        remaining = remaining / atempo.STAGE_MIN
    end

    stages[#stages + 1] = remaining

    for i, v in ipairs(stages) do
        stages[i] = "atempo=" .. string.format("%g", v)
    end

    return table.concat(stages, ",")
end

return atempo
