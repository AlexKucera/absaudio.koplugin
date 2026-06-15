-- PCM byte buffer for absaudio.koplugin
-- Pure logic (no FFI, no KOReader dependencies, no I/O).
--
-- Mutable PCM byte storage wrapping absaudio/ring_buffer's pure index math.
-- The decode producer writes PCM bytes here; the output pump reads them. It is
-- the shared mutable buffer between a decode coroutine and a scheduled output
-- pump (PRD #31, decoupled decode/output design). ring_buffer deliberately
-- stores no bytes — it only tracks cursor positions; this module owns the
-- backing byte array.
--
-- Backing representation:
--   * a Lua table indexed [0, capacity) holding integer byte values (0–255)
--   * a ring_buffer state {capacity, write, read} (absolute monotonic counters)
--     threaded forward immutably via ring_buffer.write/read after each mutation.
-- Wraparound is computed via `index % capacity` on every access.
--
-- Public API:
--   pcm_buffer.new(capacity)   → buf   (errors if capacity < 1 or non-number)
--   buf:capacity()             → number
--   buf:fill()                 → number  (bytes available to read)
--   buf:free()                 → number  (bytes writable)
--   buf:empty()                → bool
--   buf:full()                 → bool
--   buf:can_write(n)           → bool    (true iff writing n won't overrun)
--   buf:can_read(n)            → bool    (true iff reading n won't underrun)
--   buf:write(data)            → copies a Lua string of bytes into the backing
--                                 at write_slot (wraparound); errors "pcm_buffer
--                                 overrun" if !can_write(#data).
--   buf:read(n)                → Lua string of n bytes from read_slot;
--                                 errors "pcm_buffer underrun" if !can_read(n).
--   buf:clear()                → reset to empty (write=read=0)

local ring_buffer = require("absaudio/ring_buffer")

local pcm_buffer = {}

------------------------------------------------------------------------
-- Create a new mutable PCM byte buffer of the given byte capacity.
-- Errors if capacity is not a number or is less than 1.
--
-- @param capacity number  buffer capacity in bytes (>= 1)
-- @return table   buffer instance implementing the public API
------------------------------------------------------------------------
function pcm_buffer.new(capacity)
    if type(capacity) ~= "number" or capacity < 1 then
        error("pcm buffer capacity must be a number >= 1")
    end
    local state = ring_buffer.new(capacity)
    local backing = {}          -- [0, capacity) byte values
    local buf = {}

    function buf:capacity() return state.capacity end
    function buf:fill()    return ring_buffer.fill(state) end
    function buf:free()    return ring_buffer.free(state) end
    function buf:empty()   return ring_buffer.empty(state) end
    function buf:full()    return ring_buffer.full(state) end
    function buf:can_write(n) return ring_buffer.can_write(state, n) end
    function buf:can_read(n)  return ring_buffer.can_read(state, n) end

    function buf:write(data)
        local n = #data
        if not ring_buffer.can_write(state, n) then
            error("pcm_buffer overrun")
        end
        local slot = ring_buffer.write_slot(state)
        local cap = state.capacity
        for i = 1, n do
            backing[(slot + i - 1) % cap] = string.byte(data, i)
        end
        state = ring_buffer.write(state, n)
    end

    function buf:read(n)
        if not ring_buffer.can_read(state, n) then
            error("pcm_buffer underrun")
        end
        local slot = ring_buffer.read_slot(state)
        local cap = state.capacity
        local chars = {}
        for i = 0, n - 1 do
            chars[i + 1] = string.char(backing[(slot + i) % cap])
        end
        state = ring_buffer.read(state, n)
        return table.concat(chars)
    end

    function buf:clear()
        state = ring_buffer.new(state.capacity)
    end

    return buf
end

return pcm_buffer
