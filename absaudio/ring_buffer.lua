-- PCM ring-buffer index math for absaudio.koplugin
-- Pure logic (no FFI, no KOReader dependencies, no I/O).
--
-- Provides the pure index arithmetic for a fixed-capacity PCM ring buffer
-- used by the FFmpeg audio backend's decoupled decode/output design. No actual
-- PCM storage — callers maintain their own byte array; this module only tracks
-- cursor positions and computes fill/free/overrun/underrun/wraparound.
--
-- State representation:
--   { capacity = N, write = W, read = R }
-- where `write` and `read` are ABSOLUTE monotonic byte counters (they only
-- grow, never reset). `fill = write - read`. This absolute-counter convention
-- makes fill/free/overrun/underrun arithmetic trivial and exact, and doubles
-- handle long-book byte counts well within 2^52 (≈ 4.5 petabytes).
--
-- Wraparound is computed via mod when indexing the backing array:
--   write_slot = state.write % state.capacity
--   read_slot  = state.read  % state.capacity
--
-- All state is immutable: write()/read() return NEW state tables and never
-- mutate their input. Callers thread the returned state forward.
--
-- Public API:
--   rb.new(capacity)         → state  (errors if capacity < 1 or non-number)
--   rb.fill(state)           → number (bytes available to read)
--   rb.free(state)           → number (bytes writable)
--   rb.empty(state)          → bool
--   rb.full(state)           → bool
--   rb.can_write(state, n)   → bool   (true iff writing n won't overrun)
--   rb.can_read(state, n)    → bool   (true iff reading n won't underrun)
--   rb.write(state, n)       → state  (errors on overrun)
--   rb.read(state, n)        → state  (errors on underrun)
--   rb.write_slot(state)     → number (array index to write next byte)
--   rb.read_slot(state)      → number (array index to read next byte)

local ring_buffer = {}

------------------------------------------------------------------------
-- Create a new ring-buffer state for the given byte capacity.
-- Errors if capacity is not a number or is less than 1.
--
-- @param capacity number  buffer capacity in bytes (>= 1)
-- @return table   { capacity = capacity, write = 0, read = 0 }
------------------------------------------------------------------------
function ring_buffer.new(capacity)
    if type(capacity) ~= "number" or capacity < 1 then
        error("ring buffer capacity must be a number >= 1")
    end
    return { capacity = capacity, write = 0, read = 0 }
end

------------------------------------------------------------------------
-- Bytes currently in the buffer (available to read).
-- @return number
------------------------------------------------------------------------
function ring_buffer.fill(state)
    return state.write - state.read
end

------------------------------------------------------------------------
-- Free space in the buffer (bytes writable before overrun).
-- @return number
------------------------------------------------------------------------
function ring_buffer.free(state)
    return state.capacity - ring_buffer.fill(state)
end

------------------------------------------------------------------------
-- Whether the buffer has no data to read.
-- @return bool
------------------------------------------------------------------------
function ring_buffer.empty(state)
    return ring_buffer.fill(state) == 0
end

------------------------------------------------------------------------
-- Whether the buffer is completely full (no space to write).
-- @return bool
------------------------------------------------------------------------
function ring_buffer.full(state)
    return ring_buffer.fill(state) == state.capacity
end

------------------------------------------------------------------------
-- Whether n bytes can be written without overrun.
-- True iff writing n will not pass the read cursor.
--
-- @param n number  byte count to write
-- @return bool
------------------------------------------------------------------------
function ring_buffer.can_write(state, n)
    return ring_buffer.free(state) >= n
end

------------------------------------------------------------------------
-- Advance the write cursor by n bytes, returning a NEW state.
-- Errors ("ring buffer overrun") if n bytes would pass the read cursor.
-- The original state is not mutated.
--
-- @param n number  bytes to write
-- @return table    new state with write cursor advanced
------------------------------------------------------------------------
function ring_buffer.write(state, n)
    if not ring_buffer.can_write(state, n) then
        error("ring buffer overrun")
    end
    return { capacity = state.capacity, write = state.write + n, read = state.read }
end

------------------------------------------------------------------------
-- Whether n bytes can be read without underrun.
-- True iff reading n will not catch (pass) the write cursor.
--
-- @param n number  byte count to read
-- @return bool
------------------------------------------------------------------------
function ring_buffer.can_read(state, n)
    return ring_buffer.fill(state) >= n
end

------------------------------------------------------------------------
-- Advance the read cursor by n bytes, returning a NEW state.
-- Errors ("ring buffer underrun") if n bytes are not available.
-- The original state is not mutated.
--
-- @param n number  bytes to read
-- @return table    new state with read cursor advanced
------------------------------------------------------------------------
function ring_buffer.read(state, n)
    if not ring_buffer.can_read(state, n) then
        error("ring buffer underrun")
    end
    return { capacity = state.capacity, write = state.write, read = state.read + n }
end

------------------------------------------------------------------------
-- Array index where the next byte should be written.
-- Computed via mod of the absolute write counter against capacity,
-- so the index wraps around at the capacity boundary.
--
-- @return number  0-based index into the backing array
------------------------------------------------------------------------
function ring_buffer.write_slot(state)
    return state.write % state.capacity
end

------------------------------------------------------------------------
-- Array index where the next byte should be read.
-- Computed via mod of the absolute read counter against capacity,
-- so the index wraps around at the capacity boundary.
--
-- @return number  0-based index into the backing array
------------------------------------------------------------------------
function ring_buffer.read_slot(state)
    return state.read % state.capacity
end

return ring_buffer
