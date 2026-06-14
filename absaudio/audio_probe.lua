-- Audio capability probe v5 — reverse-engineer the position-read API (de-risk path B).
--
-- GOAL: determine whether GetAudioPlayingInfo() exposes a clean, readable
-- position+duration+state struct that a live-sync audio backend (path B) could
-- poll. Also confirm the read-only state getters (hw_is_audio_book_playing, etc.).
--
-- TECHNIQUE:
--   * Call GetAudioPlayingInfo() TWICE with a ~1.5s gap. The field whose value
--     CHANGES between calls is the live playback position. We know this book's
--     duration (~6425.24 s) as a fingerprint to identify the duration field.
--   * Dump the struct interpreted four ways (int32 / int64 / float / double).
--   * Only call READ-ONLY getters. Never call transport fns (hw_mp_setstate etc.)
--     — this probe must not alter playback.
--
-- SAFETY:
--   * Unknown C signatures → for GetAudioPlayingInfo we declare it as
--     (void* buf) -> void*, pass a zeroed buffer (covers the "fills out-struct"
--     pattern), AND range-check the return value against /proc/self/maps before
--     dereferencing (covers the "returns internal ptr" pattern without crashing
--     on a garbage return).
--   * Emits no sound; never opens hw:0.
--
-- RUN INSTRUCTIONS (IMPORTANT):
--   1. Start the NATIVE PocketBook audiobook player and PLAY your downloaded
--      book (so live state exists to read).
--   2. Then run this probe from the absaudio menu.
local audio_probe = {}
audio_probe.REPORT_PATH = "/mnt/ext1/absaudio_probe_report.txt"

function audio_probe.run()
    local lines = {}
    local function out(s) table.insert(lines, tostring(s)) end
    local function section(t) out(""); out("==== " .. t .. " ====") end
    local function sh(cmd)
        local h = io.popen(cmd .. " 2>/dev/null")
        if not h then return "" end
        local r = h:read("*a") or ""; h:close()
        return (r:gsub("^%s+", ""):gsub("%s+$", ""))
    end

    out("absaudio audio capability probe v5 (position-API reverse engineering)")
    out("run: " .. os.date("%Y-%m-%d %H:%M:%S"))

    local ffi_ok, ffi = pcall(require, "ffi")
    local lib  -- libinkview handle
    if ffi_ok then
        pcall(ffi.cdef, [[
            void *GetAudioPlayingInfo(void *out_buf);
            void *GetAudioOutput(void);
            int  get_audio_status(void);
            int  hw_is_audio_book_playing(void);
            int  hw_is_player_playing(void);
            int  hw_is_reader_player_playing(void);
            int  hw_is_browser_playing(void);
            int  hw_is_screen_playing(void);
            int  hw_mp_getvolume(void);
            int  GetVolume(void);
            int  IsPlayingMP3(void);
            void *dlopen(const char*, int);
            void *dlsym(void*, const char*);
            char *dlerror(void);
        ]])
        local ok, l = pcall(ffi.load, "inkview")
        if ok then lib = l; out("libinkview loaded") else out("libinkview load FAILED: "..tostring(l)) end
    else
        out("require('ffi') FAILED: "..tostring(ffi))
    end

    -- Pointer NULL test (LuaJIT NULL cdata is not == nil reliably).
    local function is_null(p)
        if p == nil then return true end
        local ok, n = pcall(function() return tonumber(ffi.cast("uintptr_t", p)) end)
        return (not ok) or n == 0
    end

    -- Build mapped-memory range list from /proc/self/maps to validate pointers.
    local maps = {}
    local mf = io.open("/proc/self/maps", "r")
    if mf then
        for line in mf:lines() do
            local a, b = line:match("^(%x+)-(%x+)%s")
            if a and b then maps[#maps+1] = { tonumber(a, 16), tonumber(b, 16) } end
        end
        mf:close()
    end
    local function in_range(p)
        if is_null(p) then return false end
        local ok, n = pcall(function() return tonumber(ffi.cast("uintptr_t", p)) end)
        if not ok then return false end
        for _, r in ipairs(maps) do if n >= r[1] and n < r[2] then return true end end
        return false
    end

    -- =====================================================================
    section("1. READ-ONLY STATE GETTERS (safe: int (void))")
    -- =====================================================================
    if lib then
        local function trycall(name)
            -- lib[name] itself can throw 'undefined symbol' for symbols we
            -- declared in cdef but that aren't exported by THIS firmware build
            -- (e.g. IsPlayingMP3). Wrap the access too, not just the call.
            local ok_lookup, fn = pcall(function() return lib[name] end)
            if not ok_lookup or not fn then
                out(string.format("  %-30s <not exported>", name)); return
            end
            local ok, v = pcall(function() return fn() end)
            if ok then out(string.format("  %-30s = %s", name, tostring(v)))
            else out(string.format("  %-30s <call failed: %s>", name, tostring(v))) end
        end
        for _, n in ipairs({"get_audio_status", "hw_is_audio_book_playing",
                            "hw_is_player_playing", "hw_is_reader_player_playing",
                            "hw_is_browser_playing", "hw_is_screen_playing",
                            "hw_mp_getvolume", "GetVolume", "IsPlayingMP3"}) do trycall(n) end
    else
        out("(libinkview not loaded — skipping)")
    end

    -- =====================================================================
    section("2. GetAudioPlayingInfo — struct dump (PASS 1)")
    -- =====================================================================
    -- Fingerprint: this book duration ~6425.24 s (~6425240 ms).
    local DUR_S, DUR_MS = 6425, 6425240
    local function near(v, target, tol) return type(v)=="number" and math.abs(v-target) <= tol end

    local function dump_struct(label, base_ptr, nbytes)
        if not (ffi_ok and base_ptr) or is_null(base_ptr) then out(label..": <null>"); return end
        if not in_range(base_ptr) then out(label..": <pointer outside mapped range; not dereferencing>"); return end
        out(string.format("%s (ptr=%s, %d bytes):", label,
            string.format("0x%x", tonumber(ffi.cast("uintptr_t", base_ptr)) or 0), nbytes))
        local n32 = math.floor(nbytes/4)
        local p32 = ffi.cast("int32_t*", base_ptr)
        local pf  = ffi.cast("float*", base_ptr)
        local p64 = ffi.cast("int64_t*", base_ptr)
        local pd  = ffi.cast("double*", base_ptr)
        for i = 0, n32 - 1 do
            local iv = tonumber(p32[i])
            local fv = tonumber(pf[i])
            local tags = {}
            if near(iv, DUR_S, 2) or near(iv, DUR_MS, 2000) then tags[#tags+1]="DUR?" end
            if near(fv, DUR_S, 2) then tags[#tags+1]="DUR(f)?" end
            if (iv == 0 or iv == 2 or iv == 3) then tags[#tags+1]="state?" end
            local tag = (#tags > 0) and ("  <" .. table.concat(tags, ",") .. ">") or ""
            out(string.format("  [%2d] i32=%-12d f=%.3f%s", i, iv, fv, tag))
        end
        -- int64 / double view (8-byte aligned)
        for i = 0, math.floor(nbytes/8) - 1 do
            local i64 = tonumber(p64[i])
            local dv  = tonumber(pd[i])
            local tags = {}
            if near(i64, DUR_MS, 2000) then tags[#tags+1]="DUR(ms)?" end
            if near(dv, DUR_S, 0.5) then tags[#tags+1]="DUR(d)?" end
            if (#tags > 0) or (i < 4) then
                local tag2 = (#tags > 0) and ("  <" .. table.concat(tags, ",") .. ">") or ""
                out(string.format("  [%2d] i64=%-14d d=%.5f%s", i, i64, dv, tag2))
            end
        end
    end

    local buf1, ret1, ok1, err1
    if ffi_ok and lib and lib.GetAudioPlayingInfo then
        buf1 = ffi.new("unsigned char[256]")
        ok1, err1 = pcall(function() ret1 = lib.GetAudioPlayingInfo(buf1) end)
        if not ok1 then out("GetAudioPlayingInfo call FAILED: "..tostring(err1))
        else
            out("PASS 1 returned without error.")
            dump_struct("  [caller buffer]", ffi.cast("void*", buf1), 256)
            dump_struct("  [return value]",  ret1, 128)
        end
    else
        out("GetAudioPlayingInfo not available")
    end

    -- =====================================================================
    section("3. GetAudioPlayingInfo — PASS 2 (1.5s later; changed field = POSITION)")
    -- =====================================================================
    -- Sleep via a busy loop (no socket/ffi.sleep dependency); ~1.5s.
    local t0 = os.time()
    while os.difftime(os.time(), t0) < 1.5 do end

    if ffi_ok and lib and lib.GetAudioPlayingInfo and ok1 then
        local buf2 = ffi.new("unsigned char[256]")
        local ret2
        local ok2 = pcall(function() ret2 = lib.GetAudioPlayingInfo(buf2) end)
        if ok2 then
            out("PASS 2 (1.5s later). Diffing caller-buffer int32 fields:")
            if in_range(ffi.cast("void*", buf1)) and in_range(ffi.cast("void*", buf2)) then
                local p1 = ffi.cast("int32_t*", buf1)
                local p2 = ffi.cast("int32_t*", buf2)
                local pf1 = ffi.cast("float*", buf1)
                local pf2 = ffi.cast("float*", buf2)
                local pd1 = ffi.cast("double*", buf1)
                local pd2 = ffi.cast("double*", buf2)
                for i = 0, 63 do
                    local a, b = tonumber(p1[i]), tonumber(p2[i])
                    if a ~= b then
                        local af, bf = tonumber(pf1[i]), tonumber(pf2[i])
                        out(string.format("  [%2d] CHANGED  i32: %d -> %d (Δ=%d)   f: %.3f -> %.3f",
                            i, a, b, b-a, af, bf))
                    end
                end
                for i = 0, 31 do
                    local a, b = tonumber(pd1[i]), tonumber(pd2[i])
                    if math.abs((a or 0)-(b or 0)) > 0.001 then
                        out(string.format("  [d%2d] CHANGED  d: %.4f -> %.4f", i, a, b))
                    end
                end
                out("  (A field that advances by ~1-2 over the 1.5s gap = live position in seconds.)")
            else
                out("  (buffers not in mapped range — skipping diff)")
            end
            dump_struct("  [return value pass 2]", ret2, 128)
        else
            out("PASS 2 failed")
        end
    end

    -- =====================================================================
    section("4. GetAudioOutput")
    -- =====================================================================
    if ffi_ok and lib and lib.GetAudioOutput then
        local ok, ao = pcall(function() return lib.GetAudioOutput() end)
        if ok and in_range(ao) then
            local s = ""
            pcall(function() s = ffi.string(ffi.cast("char*", ao)) end)
            out("GetAudioOutput (as string): "..tostring(s))
            dump_struct("GetAudioOutput", ao, 64)
        else
            out("GetAudioOutput: "..(ok and "<null/out-of-range>" or "<failed>"))
        end
    end

    -- =====================================================================
    section("5. INTERPRETATION NOTES")
    -- =====================================================================
    out("DURATION fingerprint for this book: ~6425.24 s (6425240 ms).")
    out("Any int32/float field ≈6425 or int ≈6425240 = likely DURATION.")
    out("The field that changes between PASS 1 and PASS 2 (Δ≈1-2 over 1.5s) = POSITION (seconds).")
    out("A field ==2 likely = MP_PLAYING state; ==0 = MP_STOPPED.")
    out("If a clean position+duration+state emerge here, path B (in-app hw_mp backend")
    out("with live ABS playhead sync) is viable without reverse-engineering more.")

    local report = table.concat(lines, "\n") .. "\n"
    local rf = io.open(audio_probe.REPORT_PATH, "w")
    if rf then rf:write(report); rf:close() end
    return report
end

return audio_probe
