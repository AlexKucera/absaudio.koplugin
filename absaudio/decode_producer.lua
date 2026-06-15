-- Decode producer for absaudio.koplugin (issue #34, audio slice C)
--
-- Coroutine-based decode producer for the FFmpeg audio backend (PRD #31,
-- decoupled decode/output design). It opens a file via an INJECTABLE
-- decoder_factory, decodes frames, writes PCM into a shared pcm_buffer, fires
-- position/finished/error callbacks, and yields (backpressure) when the buffer
-- is full or after a frame-quota timeshare yield. The output pump drives it by
-- calling :kick() after draining buffer space.
--
-- Pure control flow (no FFI, no KOReader dependencies). The real FFmpeg decode
-- body is filled in the device session; off-device, tests inject a FAKE
-- decoder_factory.
--
-- Public API:
--   decode_producer.new(opts) -> producer
--     opts.decoder_factory = fn(path) -> decoder | nil, err   [REQUIRED, injectable]
--     opts.path            = string                          [REQUIRED]
--     opts.buffer          = pcm_buffer instance             [REQUIRED]
--     opts.on_position     = fn(ms) optional                 (fires per frame with frame.pts_ms)
--     opts.on_finished     = fn()   optional                 (fires once at clean EOF)
--     opts.on_error        = fn(err) optional                (fires once on open/decode error)
--     opts.frame_quota     = number  (default 64)            (yield every N frames for timeshare)
--   producer:start()      -> bool   (create coroutine + resume once; false if already started/done)
--   producer:kick()       -> bool   (resume after a yield; false if not started or done)
--   producer:is_done()    -> bool   (true once finished or errored)
--   producer:status()     -> "not_started" | "running" | "finished" | "errored"
--   producer:teardown()                 (close the decoder if open; mark done; IDEMPOTENT)
--
-- Injected decoder interface (tests build fakes; device fills real FFmpeg):
--   decoder_factory(path) -> decoder | nil, err
--   decoder:read_frame() -> frame | nil(EOF) | nil, err
--     where frame = { pcm = <Lua string of bytes>, pts_ms = <number> }
--   decoder:close()

local decode_producer = {}

------------------------------------------------------------------------
-- Create a new decode producer instance.
-- @param opts table  (see module header)
-- @return table  producer instance implementing start/kick/is_done/status/teardown
------------------------------------------------------------------------
function decode_producer.new(opts)
    opts = opts or {}
    local decoder_factory = opts.decoder_factory
    local path = opts.path
    local buffer = opts.buffer
    local on_position = opts.on_position
    local on_finished = opts.on_finished
    local on_error = opts.on_error
    local frame_quota = opts.frame_quota or 64

    local status = "not_started"
    local done = false
    local co = nil
    local decoder = nil  -- open handle kept as upvalue so teardown can close it

    ----------------------------------------------------------------
    -- Coroutine body: the decode loop
    ----------------------------------------------------------------
    local function run()
        local dec, err = decoder_factory(path)
        if not dec then
            status = "errored"; done = true
            if on_error then on_error(err or "decoder open failed") end
            return
        end
        decoder = dec
        local since_yield = 0
        while true do
            local frame, ferr = dec:read_frame()
            if ferr then
                pcall(dec.close, dec); decoder = nil
                status = "errored"; done = true
                if on_error then on_error(ferr) end
                return
            end
            if frame == nil then  -- clean EOF
                pcall(dec.close, dec); decoder = nil
                status = "finished"; done = true
                if on_finished then on_finished() end
                return
            end
            -- guard: a frame bigger than the whole buffer can never be written
            if #frame.pcm > buffer:capacity() then
                pcall(dec.close, dec); decoder = nil
                status = "errored"; done = true
                if on_error then on_error("decoded frame larger than buffer capacity") end
                return
            end
            if on_position and frame.pts_ms then on_position(frame.pts_ms) end
            -- backpressure: yield until there is room for this frame
            while not buffer:can_write(#frame.pcm) do
                coroutine.yield("buffer_full")
            end
            buffer:write(frame.pcm)
            since_yield = since_yield + 1
            if since_yield >= frame_quota then
                since_yield = 0
                coroutine.yield("quota")
            end
        end
    end

    ----------------------------------------------------------------
    -- Producer instance
    ----------------------------------------------------------------
    local self = {}

    function self:status() return status end
    function self:is_done() return done end

    function self:start()
        if status ~= "not_started" then return false end
        status = "running"
        co = coroutine.create(run)
        local ok, yval = coroutine.resume(co)
        if not ok then
            status = "errored"; done = true
            if on_error then on_error(tostring(yval)) end
        end
        return true
    end

    function self:kick()
        if status ~= "running" then return false end
        if coroutine.status(co) == "dead" then return false end
        local ok, yval = coroutine.resume(co)
        if not ok then
            status = "errored"; done = true
            if on_error then on_error(tostring(yval)) end
        end
        return true
    end

    function self:teardown()
        if decoder then
            pcall(decoder.close, decoder)
            decoder = nil
        end
        if status == "not_started" or status == "running" then
            status = "errored"
        end
        done = true
    end

    return self
end

return decode_producer
