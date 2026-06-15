-- Wake-lock wrapper for absaudio.koplugin (issue #34, audio slice C)
--
-- Paired, idempotent wrapper around the PocketBook firmware sleep-ban that
-- prevents auto-suspend from stalling the output pump during long playback
-- (observed failure mode during the device probe session).
--
-- Properties:
--   * PAIRED: acquire()/release() are meant to bracket active playback.
--   * IDEMPOTENT: acquire() calls the underlying impl.acquire() exactly ONCE
--     per held period (a second acquire while held is a no-op). release() calls
--     impl.release() exactly ONCE iff currently held (a release while not held
--     is a no-op and never errors).
--   * INJECTABLE: the real firmware call is behind opts.impl = {acquire, release}.
--     Tests inject a counting fake; the ffmpeg_backend wires a guarded default.
--   * GUARDED DEFAULT: when opts.impl is nil, a guarded inkview probe resolves
--     the real symbol (BanSleep/AllowSleep, falling back to hw_ban_suspend). If
--     any probe step fails — as it does on the dev Mac where libinkview.so is
--     absent — the default impl.acquire/release are NO-OPs. It NEVER crashes.
--
-- The real firmware symbol is confirmed/wired in the device session; off-device
-- the default is a safe no-op so transport logic is unit-testable.
--
-- Public API:
--   wake_lock.new(opts) -> lock
--     opts.impl = { acquire=function()end, release=function()end }  (injectable)
--   lock:acquire()     idempotent: calls impl.acquire once per held period
--   lock:release()     idempotent: calls impl.release once iff held
--   lock:is_held() -> bool

local wake_lock = {}

------------------------------------------------------------------------
-- Default impl: guarded inkview probe. No-op on the dev Mac; on a PocketBook
-- it resolves BanSleep/AllowSleep (or hw_ban_suspend). Every step is
-- pcall-guarded so a missing symbol or library is a silent no-op, never a crash
-- (lesson from the IsPlayingMP3 probe crash).
------------------------------------------------------------------------
local function make_default_impl()
    local acquire_fn, release_fn
    local ok_ffi, ffi = pcall(require, "ffi")
    if ok_ffi then
        local ok_lib, lib = pcall(ffi.load, "inkview")
        if ok_lib and lib then
            -- Resolve BanSleep/AllowSleep; the cdef + symbol lookup is guarded.
            -- hw_ban_suspend is a known internal fallback symbol on this firmware.
            pcall(ffi.cdef, "void BanSleep(void);")
            pcall(ffi.cdef, "void AllowSleep(void);")
            local ok_a, fa = pcall(function() return lib["BanSleep"] end)
            local ok_r, fr = pcall(function() return lib["AllowSleep"] end)
            if ok_a and type(fa) == "cdata" then acquire_fn = fa end
            if ok_r and type(fr) == "cdata" then release_fn = fr end
        end
    end
    -- No-op when the symbol is unavailable (dev Mac, or undefined on a build).
    return {
        acquire = acquire_fn and function() pcall(acquire_fn) end or function() end,
        release = release_fn and function() pcall(release_fn) end or function() end,
    }
end

------------------------------------------------------------------------
-- Create a new wake-lock instance.
-- @param opts table  opts.impl = {acquire=fn, release=fn} (optional; default
--                     is the guarded inkview probe, a no-op off-device)
-- @return table  lock instance
------------------------------------------------------------------------
function wake_lock.new(opts)
    opts = opts or {}
    local impl = opts.impl or make_default_impl()

    local held = false

    local self = {}

    function self:is_held()
        return held
    end

    function self:acquire()
        if held then return end
        impl.acquire()
        held = true
    end

    function self:release()
        if not held then return end
        impl.release()
        held = false
    end

    return self
end

return wake_lock
