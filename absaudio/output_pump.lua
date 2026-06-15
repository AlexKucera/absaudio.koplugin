-- Output pump for absaudio.koplugin (issue #34, audio slice C)
--
-- The output consumer of the FFmpeg audio backend's decoupled decode/output
-- design (PRD #31): a scheduled ~50ms pump that drains PCM from the shared
-- pcm_buffer to an INJECTABLE sink (real ALSA on device), drives the decode
-- producer via backpressure (producer:kick()), survives underrun (empty
-- buffer), and self-stops when the producer is done and the buffer is drained.
--
-- The producer is injected via opts (the module does NOT require decode_producer
-- — it only calls producer:kick() and producer:is_done()). The sink, schedule,
-- and interval/chunk_size are all injectable so the full control flow is unit-
-- testable off-device with fakes. The real ALSA body + UIManager schedule land
-- in the device session.
--
-- Public API:
--   output_pump.new(opts) -> pump
--     opts.buffer     = pcm_buffer instance                     [REQUIRED]
--     opts.sink       = { write = fn(data_string, n) }          [REQUIRED]
--     opts.producer   = { kick = fn()->bool, is_done = fn()->bool }  [REQUIRED]
--     opts.schedule   = fn(delay_seconds, fn) -> cancel_fn      [default: lazy UIManager:scheduleIn]
--     opts.interval   = number seconds (default 0.05)
--     opts.chunk_size = number bytes per tick   (default 4096)
--     opts.on_drained = fn()  optional  (fires once when producer done AND buffer empty)
--   pump:start()         -> bool   (schedule first tick; false if already running)
--   pump:tick()                   (drain up to chunk_size -> sink.write; kick producer;
--                                  if done+empty -> stop + on_drained; else reschedule)
--   pump:stop()                  (cancel scheduled tick; idempotent)
--   pump:is_running() -> bool

local output_pump = {}

------------------------------------------------------------------------
-- Default schedule: lazy UIManager:scheduleIn. Only used when opts.schedule
-- is nil (on device). Tests always inject a fake schedule. Returns a cancel fn.
------------------------------------------------------------------------
local function default_schedule(delay, fn)
    local ok, UIManager = pcall(require, "ui/uimanager")
    if ok and UIManager.scheduleIn then
        return UIManager:scheduleIn(delay, fn)
    end
    return function() end  -- no-op cancel when UIManager unavailable
end

------------------------------------------------------------------------
-- Create a new output pump.
-- @param opts table  (see module header)
-- @return table  pump instance
------------------------------------------------------------------------
function output_pump.new(opts)
    opts = opts or {}
    local buffer = opts.buffer
    local sink = opts.sink
    local producer = opts.producer
    local schedule = opts.schedule or default_schedule
    local interval = opts.interval or 0.05
    local chunk_size = opts.chunk_size or 4096
    local on_drained = opts.on_drained

    local running = false
    local cancel_handle = nil

    local self = {}

    function self:is_running()
        return running
    end

    function self:start()
        if running then return false end
        running = true
        cancel_handle = schedule(interval, function() self:tick() end)
        return true
    end

    function self:stop()
        if cancel_handle then cancel_handle() end
        cancel_handle = nil
        running = false
    end

    function self:tick()
        if not running then return end
        -- 1. drain available bytes (up to chunk_size) to the sink
        local avail = buffer:fill()
        if avail > 0 then
            local n = math.min(avail, chunk_size)
            local data = buffer:read(n)
            sink.write(data, n)
        end
        -- 2. backpressure: drive the producer to refill (no-op if done)
        if not producer:is_done() then
            producer:kick()
        end
        -- 3. natural end: producer finished AND buffer fully drained
        if producer:is_done() and buffer:empty() then
            running = false
            if on_drained then on_drained() end
            return          -- do NOT reschedule
        end
        -- 4. reschedule next tick
        cancel_handle = schedule(interval, function() self:tick() end)
    end

    return self
end

return output_pump
