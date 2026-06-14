-- Audio capability probe v4 — extract the native audio API.
--
-- CONTEXT: v3 discovered libaudio-engine.so + a full FFmpeg/Libav decode stack
-- (libavcodec/avformat/avutil/swresample) + libasound + the safe tts_sm ALSA
-- loopback chain on the PB700K3. The native audiobook player (bookshelf.app /
-- reader_controller.app) links libaudio-engine.so. This probe dumps that
-- library's EXPORTED SYMBOLS so we can design a real audio backend (play/seek/
-- pause/position/speed) against the actual API.
--
-- METHOD: a pure-Lua ELF32 .dynsym/.dynstr parser. Exported symbol names live
-- verbatim in the .dynstr section, so dumping it yields the complete public API.
-- No external tools (readelf/nm) — none exist on the stock device.
--
-- SAFETY: DETECTION-ONLY (no PlayFile/aplay/hw:0). Emits no sound.
local audio_probe = {}
audio_probe.REPORT_PATH = "/mnt/ext1/absaudio_probe_report.txt"

-- ---------------------------------------------------------------------------
-- Pure-Lua ELF32 reader (little-endian). Reads u16/u32 from a byte string.
-- ---------------------------------------------------------------------------
local function u16le(s, off)
    if off < 1 or off + 1 > #s then return nil end
    local b0, b1 = s:byte(off, off + 1)
    return b0 + b1 * 256
end
local function u32le(s, off)
    if off < 1 or off + 3 > #s then return nil end
    local b0, b1, b2, b3 = s:byte(off, off + 3)
    return b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
end
local function cstr(s, off)
    -- read NUL-terminated string starting at byte offset off (1-based)
    local endp = s:find(string.char(0), off, true)
    if not endp then return s:sub(off) end
    return s:sub(off, endp - 1)
end

--- Parse an ELF binary and return its exported symbol names (functions + objects).
-- @param blob string  full file bytes
-- @return array of {name=, type=, value=} (type: "func"/"obj"/"other"), or {} on failure
local function elf_exports(blob)
    if not blob or #blob < 52 then return {}, "too small" end
    if blob:sub(1, 4) ~= "\127ELF" then return {}, "not ELF" end
    local ei_class = blob:byte(5)       -- 1=32-bit, 2=64-bit
    local ei_data = blob:byte(6)        -- 1=little-endian
    if ei_class ~= 1 then return {}, "not ELF32 (class=" .. tostring(ei_class) .. ")" end
    if ei_data ~= 1 then return {}, "not little-endian" end

    local e_shoff = u32le(blob, 33)     -- section header table offset
    local e_shentsize = u16le(blob, 47)
    local e_shnum = u16le(blob, 49)
    local e_shstrndx = u16le(blob, 51)
    if not (e_shoff and e_shentsize and e_shnum) then return {}, "bad header" end

    -- Section header layout (Elf32_Shdr, 40 bytes, 1-based byte offsets):
    --  sh_name(1,4) sh_type(5,4) sh_flags(9,4) sh_addr(13,4) sh_offset(17,4)
    --  sh_size(21,4) sh_link(25,4) sh_info(29,4) sh_addralign(33,4) sh_entsize(37,4)
    local SHT_DYNSYM = 11
    local sections = {}
    for i = 0, e_shnum - 1 do
        local base = e_shoff + i * e_shentsize + 1  -- +1 -> 1-based
        local sh_type = u32le(blob, base + 4)
        table.insert(sections, {
            sh_name   = u32le(blob, base),
            sh_type   = sh_type,
            sh_offset = u32le(blob, base + 16),
            sh_size   = u32le(blob, base + 20),
            sh_link   = u32le(blob, base + 24),
            sh_entsize= u32le(blob, base + 36),
        })
    end

    -- Find .shstrtab to name sections (optional) and .dynsym.
    local function section_strtab(idx)
        if idx < 1 or idx > #sections then return nil end
        local s = sections[idx]
        if not (s.sh_offset and s.sh_size) then return nil end
        return blob:sub(s.sh_offset + 1, s.sh_offset + s.sh_size)
    end
    local shstrtab = (e_shstrndx and e_shstrndx < #sections) and section_strtab(e_shstrndx + 1) or nil
    local function section_name(i)
        if not shstrtab then return "" end
        return cstr(shstrtab, sections[i].sh_name + 1) or ""
    end

    local exports = {}
    for i, s in ipairs(sections) do
        local is_dynsym = (s.sh_type == SHT_DYNSYM)
        if not is_dynsym and shstrtab then
            local nm = section_name(i)
            if nm == ".dynsym" then is_dynsym = true end
        end
        if is_dynsym and s.sh_entsize and s.sh_entsize >= 16 and s.sh_link then
            local strtab = section_strtab(s.sh_link + 1)  -- +1: sh_link is 0-based; sections[] is 1-based
            if strtab then
                local n = math.floor(s.sh_size / s.sh_entsize)
                for k = 0, n - 1 do
                    local so = s.sh_offset + k * s.sh_entsize + 1  -- 1-based
                    local st_name = u32le(blob, so)
                    local st_info = blob:byte(so + 12)
                    if st_name and st_name ~= 0 then
                        local name = cstr(strtab, st_name + 1)
                        if name and #name > 0 and not name:match("^%$") then
                            local bind = (st_info and (math.floor(st_info / 16))) or 0
                            local stype = (st_info and (st_info % 16)) or 0
                            -- GLOBAL(1)/WEAK(2) bindings + FUNC(2)/OBJECT(1) types = real exports
                            if (bind == 1 or bind == 2) and name:sub(1,1) ~= "_" then
                                table.insert(exports, { name = name,
                                    type = (stype == 2 and "func") or (stype == 1 and "obj") or "other" })
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(exports, function(a, b) return a.name < b.name end)
    return exports
end

-- ---------------------------------------------------------------------------
function audio_probe.run()
    local lines = {}
    local function out(s) table.insert(lines, tostring(s)) end
    local function section(t) out(""); out("==== " .. t .. " ====") end
    local function sh(cmd)
        local h = io.popen(cmd .. " 2>/dev/null")
        if not h then return "" end
        local r = h:read("*a") or ""
        h:close()
        return (r:gsub("^%s+", ""):gsub("%s+$", ""))
    end
    local function exists(p) local f=io.open(p,"r"); if not f then return false end; f:close(); return true end

    out("absaudio audio capability probe v4")
    out("run: " .. os.date("%Y-%m-%d %H:%M:%S"))

    -- Libraries to dump (v3 found these in /ebrmain/cramfs/lib = /usr/lib = /ebrmain/lib).
    local targets = {
        { path = "/ebrmain/cramfs/lib/libaudio-engine.so", why = "native player engine (PRIMARY)" },
        { path = "/usr/lib/libaudio-engine.so",            why = "alternate location" },
        { path = "/ebrmain/cramfs/lib/libavcodec.so.60.31.102", why = "FFmpeg: confirm AAC/m4b decoder" },
        { path = "/ebrmain/cramfs/lib/libframework2.so",   why = "possible high-level media facade" },
        { path = "/ebrmain/cramfs/lib/libinkview.so",      why = "cross-check exports vs v2/v3 scans" },
    }

    -- Highlight names matching these patterns (likely audio-control API).
    local hot_patterns = { "play", "pause", "seek", "position", "duration", "speed",
                           "track", "open", "load", "init", "volume", "audio", "media",
                           "player", "stop", "resume", "chapter", "percent", "time" }

    for _, t in ipairs(targets) do
        section(t.path)
        out("  (" .. t.why .. ")")
        if not exists(t.path) then
            out("  <not found>")
        else
            local f = io.open(t.path, "rb")
            local blob = f and f:read("*a"); if f then f:close() end
            if not blob then out("  <unreadable>"); goto continue end
            out(string.format("  size: %d bytes", #blob))
            local exports, err = elf_exports(blob)
            if err then out("  ELF parse: " .. err) end
            out(string.format("  exported symbols: %d", #exports))
            -- Print every export if few; otherwise print hot matches + a count.
            local hot, others = {}, {}
            for _, e in ipairs(exports) do
                local ln = e.name:lower()
                local is_hot = false
                for _, p in ipairs(hot_patterns) do
                    if ln:find(p, 1, true) then is_hot = true; break end
                end
                if is_hot then table.insert(hot, e.name)
                else table.insert(others, e.name) end
            end
            out("  -- HOT (audio-control candidates): " .. #hot .. " --")
            for _, n in ipairs(hot) do out("    " .. n) end
            -- Dump all exports if the lib is small (libaudio-engine likely is).
            if #exports <= 250 then
                out("  -- ALL exports (" .. #exports .. ") --")
                for _, e in ipairs(exports) do
                    out(string.format("    %-10s %s", e.type, e.name))
                end
            else
                out("  -- (large lib; " .. #others .. " non-hot exports omitted) --")
            end
        end
        ::continue::
    end

    -- =====================================================================
    section("NATIVE PLAYER PROCESS LIBS (start the native player first for best data)")
    -- =====================================================================
    local pids = sh("ps | grep -iE 'bookshelf|reader_controller|pocketbook' | grep -v grep | grep -v audio_probe")
    if pids ~= "" then
        out("-- candidate native-app processes:")
        out(pids)
        for pid in pids:gmatch("(%d+)") do
            local maps = sh("cat /proc/" .. pid .. "/maps 2>/dev/null | grep -iE '\\.so' | awk '{print $6}' | sort -u")
            local audio_libs = {}
            for line in (maps or ""):gmatch("[^\n]+") do
                if line:lower():find("audio", 1, true) or line:lower():find("media", 1, true)
                   or line:lower():find("avcodec", 1, true) or line:lower():find("framework", 1, true) then
                    table.insert(audio_libs, line)
                end
            end
            if #audio_libs > 0 then
                out("-- pid " .. pid .. " audio/media libs loaded:")
                for _, l in ipairs(audio_libs) do out("    " .. l) end
            end
        end
    else
        out("-- no native app process detected (unusual; player may not be running)")
    end

    -- =====================================================================
    section("SUMMARY")
    -- =====================================================================
    out("Goal: identify a clean C API in libaudio-engine.so (play/seek/pause/")
    out("position/speed). If exports include such functions, an FFI backend")
    out("routed through the system's FFmpeg + ALSA tts_sm chain is viable with")
    out("full speed+seek+position on the PB700K3 — using the firmware's own")
    out("safe amplifier-managed path.")

    local report = table.concat(lines, "\n") .. "\n"
    local rf = io.open(audio_probe.REPORT_PATH, "w")
    if rf then rf:write(report); rf:close() end
    return report
end

return audio_probe
