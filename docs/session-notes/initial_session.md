Yes — this is very doable, and for a “simple download + local playback + position sync” plugin I’d classify it as a **medium** solo project rather than a moonshot. KOReader plugins are written in Lua, the frontend/plugin side is scriptable without touching the C backend, and there are already KOReader plugins that integrate with external APIs plus an existing audiobook plugin you could study or fork.[1][2][3]

## Complexity

The easiest version is a KOReader plugin that authenticates to Audiobookshelf, lists your audiobooks, downloads files to local storage, opens them with either PocketBook audio handling or an existing KOReader audio plugin, and periodically pushes progress back to Audiobookshelf through its progress/session endpoints.[3][4][5]
That is much simpler than building a full streaming client, waveform UI, transcoding support, or an offline library manager.[4][5]

I’d roughly score it like this:  
- Basic downloader browser: 2/5 difficulty.[2][1]
- Playback handoff on PocketBook: 3/5 difficulty, mostly because device-specific audio behavior is fiddly.[6][3]
- Reliable position sync: 3/5 difficulty, because you need to map local state to ABS item/session IDs and sync at the right moments.[5][4]
- Polished UX/error handling: 4/5 difficulty.[1][2]

## Why it’s feasible

KOReader’s plugin system is explicitly designed for Lua-based extensions, with plugin folders, `_meta.lua`, `main.lua`, UI widgets, networking, settings storage, timers, and menu integration available to plugins.[7][8][1]
There are also real examples of third-party KOReader plugins that talk to self-hosted services, such as a Readeck plugin with server URL, auth, settings, and browse actions, so the architectural pattern already exists.[2]

On the Audiobookshelf side, the server exposes progress and session APIs, and the maintainers explicitly note that third-party clients are responsible for calling the sync/update endpoints when playback changes.[9][4][5]
That means your idea aligns with how ABS is already meant to integrate with external clients.[4][9]

## Hard parts

The biggest uncertainty is **playback control**, not downloading or API access. KOReader is primarily a reader app, and while `audiobook.koplugin` shows audiobook/audio support on PocketBook, audio behavior across e-ink devices is still more niche and less standardized than ebook handling.[3][6]
If you can reuse that plugin’s playback layer instead of inventing your own player, the project gets much easier.[3]

The second tricky bit is sync semantics. Audiobookshelf supports progress/session sync, but you need to decide whether to use direct progress updates, session sync, or both; then handle pause, resume, stop, completed, and “user jumped chapters” cleanly.[5][4]
The good news is you do not need fancy realtime sync at first; syncing on pause, app close, chapter change, and every 30–60 seconds during playback is enough for a solid v1.[4][5]

## Suggested architecture

A practical v1 would look like this:  
- Auth/settings screen: ABS URL, token, download folder.[9][2]
- Library browser: show audiobooks, episodes/files, download button, resume button.[1][2]
- Download manager: store local manifest with ABS item ID, file path, duration, last position.[7][1]
- Playback adapter: either invoke an existing KOReader audio plugin or a PocketBook-capable playback layer.[6][3]
- Sync service: call ABS progress/session endpoints on interval and state changes.[5][4]

If you keep it to **single-user, DRM-free M4B/MP3, one device family, no streaming, no transcoding**, the scope stays sane.[3][5]

## Time estimate

For someone technical using LLMs heavily, I’d estimate:  
- Proof of concept: 1–3 weekends.[2][1][5]
- Usable personal plugin: 2–6 weeks part-time.[4][3]
- Something robust enough to publish for others: 1–3 months, mostly for testing, edge cases, and PocketBook-specific weirdness.[6][3]

LLMs should help a lot with Lua boilerplate, API wrappers, manifest formats, and menu/UI scaffolding, but they will not replace device testing or KOReader event-model debugging.[8][1]
In other words, LLMs can probably get you to 70–80% quickly, while the final 20% is hardware-specific glue and sync correctness.[3][4]

## My take

For **your** use case, I think this is a good hack project if you buy the Era and are fine with “good enough for me” rather than “production-ready for everyone.”[4][3]
The smart move would be to build it as a thin ABS integration layer on top of existing KOReader/PocketBook audio functionality, not as a full standalone audiobook engine.[1][3]

A very reasonable MVP is: browse ABS library, download audiobook, resume local playback, sync position on pause/exit.[5][4]
That MVP is absolutely in reach for one experienced tinkerer with LLM assistance.[8][2][1]

Would you like a concrete MVP plan next, with plugin folder structure, API endpoints to hit, and which parts to borrow from existing KOReader plugins?

Sources
[1] Development Guide - KOReader Documentation https://koreader.rocks/doc/topics/Development_guide.md.html
[2] GitHub - flip-rossi/readeck.koplugin: An unofficial KOReader plugin to add integration with your Readeck instance. https://github.com/flip-rossi/readeck.koplugin
[3] stradichenko/audiobook.koplugin: A plugin to give TTS- ... https://github.com/stradichenko/audiobook.koplugin
[4] Progress Sync between ABS and ThirdPartyClients like Shelfplayer · advplyr/audiobookshelf · Discussion #3538 https://github.com/advplyr/audiobookshelf/discussions/3538
[5] Update:API route for getting playback session and getting media ... https://git.laurivan.com/Mirrors/audiobookshelf/commit/bf928692d5b43ebbe147606b33c41445089e7e81?files=server%2Frouters
[6] Audiobook plugin for KOReader [v0.1.9]! With even more ... https://www.reddit.com/r/koreader/comments/1tjyxrq/audiobook_plugin_for_koreader_v019_with_even_more/
[7] 插件 API 参考 | koreader/koreader https://opendeep.wiki/koreader/koreader/plugin-api-reference
[8] DEVELOPING YOUR FIRST PLUGIN FOR KOREADER https://kindlemodshelf.me/koreaderplugindev
[9] a Docker image https://www.audiobookshelf.org/docs/
[10] KOReader Documentation https://koreader.rocks/doc/
[11] KOReader User Guide https://koreader.rocks/user_guide/
[12] Developing Your First KOReader Plugin https://kindlemodshelf.me/koreaderplugindev.html
[13] Add:API endpoint to get continue listening items across all libraries ... https://git.laurivan.com/Mirrors/audiobookshelf/commit/9f200ece99f1fedbe01add31af96b99e1c9caea7?files=server%2Fcontrollers
[14] reuerendo/pocketbooktools.koplugin: Plugin for KOReader ... https://github.com/reuerendo/pocketbooktools.koplugin
[15] KOPlugin.md https://gist.github.com/consoleaf/abbe8449377f1f6ef47b86d6c0d8873d

Yes — here’s the concrete MVP plan I’d use. The short version is: build a thin KOReader plugin in Lua that stores an ABS API key, fetches audiobook items from your server, downloads the selected file to local storage, launches playback through an existing PocketBook-capable audio path, and writes progress back to ABS on a timer plus on pause/stop/exit.[1][2][3]

## Scope

Keep v1 brutally small: one user, one ABS server, audiobook libraries only, local download only, no streaming, no transcoding, and preferably M4B/MP3 first.[4][1]
That scope is small enough that an LLM can generate a lot of the glue code, while you focus on the device-specific parts and sync correctness.[2][5]

## Plugin layout

Start from KOReader’s `hello.koplugin` pattern: copy an existing simple plugin folder, then create `absaudio.koplugin/_meta.lua` and `absaudio.koplugin/main.lua`, because KOReader plugins are just Lua packages registered through that structure.[5][6][7]
For settings, use KOReader’s Lua settings storage rather than inventing your own config format, since KOReader already exposes persistent settings helpers.[8][9]

A practical folder layout would be:

- `absaudio.koplugin/_meta.lua`
- `absaudio.koplugin/main.lua`
- `absaudio.koplugin/abs_client.lua`
- `absaudio.koplugin/downloads.lua`
- `absaudio.koplugin/player_adapter.lua`
- `absaudio.koplugin/progress_sync.lua`
- `absaudio.koplugin/state.lua`

That split keeps LLM prompts focused and testable.[9][2]

## Menus and settings

Your plugin should register one main menu entry such as “Audiobookshelf,” then expose sub-items for Server Settings, Browse Library, Active Download, Resume Last Book, and Sync Now. KOReader plugins commonly register into the main menu this way, and settings dialogs can be built with the existing KOReader widget/dialog stack.[2][9]
Use an ABS API key instead of username/password, because Audiobookshelf documents API keys as the recommended auth path with `Authorization: Bearer <key>`.[1]

Store only these fields in v1:

- ABS base URL
- API key
- download directory
- selected library ID
- sync interval, e.g. 30 or 60 seconds
- “mark finished at percent” threshold, e.g. 98%

That is enough for a working personal plugin.[8][1]

## ABS endpoints

The simplest ABS flow is:

1. Call the libraries endpoint to list libraries and choose the audiobook library.[4][1]
2. List items in that library and show title, author, duration, and resume state if available.[10][4]
3. For one selected item, fetch expanded item/media details so you know the audio tracks/files and item IDs.[4]
4. Download the chosen media file locally with the Bearer token.[1][4]
5. Send progress/session updates back during playback and on stop.[11][12]

Because ABS has evolving APIs, I’d code your client around a tiny wrapper module with only 5–6 calls, not around a giant generated client. That keeps maintenance sane.[12][4]

## Local state model

Do not rely only on playback callbacks. Keep a tiny local manifest per downloaded book with:

- `abs_item_id`
- `abs_library_id`
- `local_path`
- `duration_seconds`
- `last_position_seconds`
- `last_synced_seconds`
- `finished`
- `etag_or_hash_optional`

KOReader already has sidecar/settings infrastructure, and you can either use a dedicated settings file or one state file per audiobook.[13][8]
This local manifest is what makes recovery and resuming sane when the device crashes or sleeps.[13]

## Playback strategy

This is the most important design decision: **do not write a player first**. Reuse an existing audio-capable path. The strongest starting point is to inspect or fork `audiobook.koplugin`, because it already targets KOReader, supports PocketBook better than generic examples, and handles audiobook-ish concerns like chapters and Bluetooth audio.[3][14]
Your plugin can then become an ABS browser/downloader/sync layer that hands a local file plus some metadata to the player layer.[3]

That keeps your problem small:

- Your plugin owns auth, browsing, downloading, manifests, sync.
- Existing audio code owns play/pause/seek/current position.

That is the right architectural cut for an MVP.[2][3]

## Progress sync logic

For v1, sync on these events only:

- playback starts
- every 30–60 seconds during playback
- pause
- chapter skip / seek
- app close
- completion

Audiobookshelf discussion around third-party progress sync makes clear that clients need to explicitly report progress changes, especially for downloaded/offline content.[11]
So your `progress_sync.lua` should treat ABS as the source of truth eventually, but not on every second tick; interval sync plus final flush is enough.[12][11]

A sensible rule set:

- If progress moved by at least 15 seconds since last sync, send update.
- If user paused or stopped, sync immediately.
- If progress >= 98%, mark finished.
- On reopen, compare local progress vs ABS progress and use the furthest position unless the server timestamp is clearly newer.

That last conflict rule is not from docs but is the kind of practical policy you’ll need because PocketBook sleep/crash behavior won’t be perfect. The API surface supports syncing; your plugin has to define the reconciliation logic.[11][12]

## Suggested build order

Build in this order so you always have something testable:

1. **Hello plugin shell**: menu entry + info dialog.[6][9]
2. **Settings UI**: base URL, API key, test connection button.[9][1]
3. **Library fetch**: list audiobook libraries and items.[1][4]
4. **Download one file**: download selected book to a known folder.[4][1]
5. **Playback handoff**: open that file through your chosen audio layer.[3]
6. **Capture position**: prove you can read current playhead reliably.[14][3]
7. **Push progress to ABS**: manual “sync now” button first.[12][11]
8. **Automatic timer sync**: background interval while playing.[11]
9. **Resume flow**: “resume last book” from local manifest or ABS state.[13][4]
10. **Conflict handling**: local vs server position policy.

If you go in that order, you avoid burning a weekend on sync logic before you even know playback works on your Era.[14][3]

## LLM-friendly prompts

This project is unusually well-suited to LLM-assisted coding if you keep prompts narrow. Good prompt chunks would be:

- “Write a KOReader Lua plugin skeleton with `_meta.lua` and `main.lua` that adds an ‘Audiobookshelf’ menu entry.”[6][9]
- “Write a Lua settings module using KOReader `LuaSettings` for base URL, API key, download dir, sync interval.”[8][9]
- “Write a minimal Lua HTTP wrapper for ABS with Bearer auth and JSON decode.”[1][4]
- “Write a manifest manager that stores audiobook state keyed by ABS item ID.”
- “Write a progress sync module that sends updates every 60 seconds and on pause/stop.”

That decomposition is exactly the kind of thing LLMs are decent at.[5][2]

## Risks

The main technical risks are:

- PocketBook-specific playback hooks may be awkward or underdocumented.[14][3]
- KOReader’s plugin APIs are documented, but examples are still more valuable than docs alone.[6][2]
- ABS endpoint details may shift over time, so your wrapper should be defensive and easy to tweak.[12][4]

The biggest project risk is not coding skill; it is getting pulled into building a “real client” instead of the thin integration layer you actually need.[2][3]

## Personal estimate

For you, with LLM help and your technical background, I think a first working MVP is realistic in about 2–4 focused weekends, assuming you can piggyback on existing audio playback code.[3][2]
If you have to build or heavily modify the player layer yourself, it could easily double.[14][3]

My recommendation would be:

- Buy the Era only if you’re okay with this being a hobby integration project.[15][3]
- Start by proving playback handoff from a local M4B file in KOReader/PocketBook.
- Only then build ABS download and sync around it.

Would you like me to draft the actual file skeleton next, including `_meta.lua`, `main.lua`, and the stub modules for `abs_client.lua`, `state.lua`, and `progress_sync.lua`?

Sources
[1] Creating API Keys https://www.audiobookshelf.org/guides/api-keys/
[2] Development Guide - KOReader Documentation https://koreader.rocks/doc/topics/Development_guide.md.html
[3] stradichenko/audiobook.koplugin: A plugin to give TTS- ... https://github.com/stradichenko/audiobook.koplugin
[4] Audiobookshelf API Reference https://api.audiobookshelf.org
[5] DEVELOPING YOUR FIRST PLUGIN FOR KOREADER https://kindlemodshelf.me/koreaderplugindev
[6] Writing a Plugin for KOReader · Issue #6084 https://github.com/koreader/koreader/issues/6084
[7] View Single Post - How to execute a .lua script in KOReader? https://www.mobileread.com/forums/showpost.php?p=4505068&postcount=4
[8] Module luasettings https://koreader.rocks/doc/modules/luasettings.html
[9] Building a koreader plugin - tahnok's notes https://notes.tahnok.ca/blog/Building+a+koreader+plugin
[10] audiobookshelf-api-docs/source/includes/_libraries.md at main · audiobookshelf/audiobookshelf-api-docs https://github.com/audiobookshelf/audiobookshelf-api-docs/blob/main/source/includes/_libraries.md
[11] Progress Sync between ABS and ThirdPartyClients like Shelfplayer · advplyr/audiobookshelf · Discussion #3538 https://github.com/advplyr/audiobookshelf/discussions/3538
[12] Update:API route for getting playback session and getting media ... https://git.laurivan.com/Mirrors/audiobookshelf/commit/bf928692d5b43ebbe147606b33c41445089e7e81?files=server%2Frouters
[13] Module docsettings https://koreader.rocks/doc/modules/docsettings.html
[14] Audiobook plugin for KOReader [v0.1.9]! With even more ... https://www.reddit.com/r/koreader/comments/1tjyxrq/audiobook_plugin_for_koreader_v019_with_even_more/
[15] Pocketbook eReader Vergleich. Which one to get? https://www.perplexity.ai/search/437af31e-f11a-4594-8783-0f9d56536b02
[16] koreader-plugin-wattpad/README.md at main https://github.com/aoyn1xw/koreader-plugin-wattpad/blob/main/README.md
[17] How to create plugins : r/koreader https://www.reddit.com/r/koreader/comments/1mol4lh/how_to_create_plugins/
[18] How to execute a .lua script in KOReader? https://www.mobileread.com/forums/showthread.php?p=4505068
[19] luizcorreia/metaguiding.koplugin https://github.com/luizcorreia/metaguiding.koplugin
[20] GitHub - Teekeks/audiobookshelfAPI: Python implementation of the Audiobookshelf API https://github.com/Teekeks/audiobookshelfAPI


Below is a good **starter skeleton** for an Audiobookshelf KOReader plugin. It follows the normal KOReader plugin structure with `_meta.lua` and `main.lua`, uses persistent settings via `LuaSettings`, and authenticates to Audiobookshelf with a Bearer API key as documented by ABS.[1][2][3]

This is intentionally an **MVP scaffold**, not finished production code: it gives you clean module boundaries for browsing, downloading, playback handoff, and progress sync, so you can let LLMs fill in each part iteratively.[4][5]

## Folder layout

Create a folder like this inside your KOReader `plugins` directory, because KOReader expects a `.koplugin` folder containing at least `_meta.lua` and `main.lua`.[6][1]

```text
absaudio.koplugin/
├── _meta.lua
├── main.lua
├── abs_client.lua
├── state.lua
├── downloads.lua
├── player_adapter.lua
└── progress_sync.lua
```

## _meta.lua

This is the plugin descriptor KOReader uses to discover and load the plugin.[1]

```lua
local _ = require("gettext")

return {
    name = "absaudio",
    fullname = _("Audiobookshelf Audio"),
    description = _("Download audiobooks from Audiobookshelf, play locally, and sync progress."),
}
```

## main.lua

This is the entry point. It should own menu registration, lazy-load your modules, and glue together settings, browsing, download, playback, and sync. KOReader plugins are typically structured this way.[4][1]

```lua
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local LuaSettings = require("luasettings")

local ABSClient = require("plugins/absaudio.koplugin/abs_client")
local State = require("plugins/absaudio.koplugin/state")
local Downloads = require("plugins/absaudio.koplugin/downloads")
local PlayerAdapter = require("plugins/absaudio.koplugin/player_adapter")
local ProgressSync = require("plugins/absaudio.koplugin/progress_sync")

local ABSAudio = WidgetContainer:extend{
    name = "absaudio",
    is_doc_only = false,
}

function ABSAudio:init()
    self.settings = LuaSettings:open("absaudio.lua")
    self.state = State:new(self.settings)
    self.client = ABSClient:new(self.settings)
    self.downloads = Downloads:new(self.settings, self.client, self.state)
    self.player = PlayerAdapter:new(self.settings, self.state)
    self.sync = ProgressSync:new(self.settings, self.client, self.state, self.player)

    self.ui.menu:registerToMainMenu(self)
end

function ABSAudio:addToMainMenu(menu_items)
    menu_items.audiobookshelf_audio = {
        text = _("Audiobookshelf Audio"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Server settings"),
                callback = function() self:showSettingsDialog() end,
            },
            {
                text = _("Test connection"),
                callback = function() self:testConnection() end,
            },
            {
                text = _("Browse library"),
                callback = function() self:browseLibrary() end,
            },
            {
                text = _("Resume last book"),
                callback = function() self:resumeLastBook() end,
            },
            {
                text = _("Sync now"),
                callback = function() self.sync:syncCurrent(true) end,
            },
        }
    }
end

function ABSAudio:showSettingsDialog()
    local dialog = MultiInputDialog:new{
        title = _("Audiobookshelf Settings"),
        fields = {
            {
                text = _("Base URL"),
                input = self.settings:readSetting("base_url") or "",
                hint = "https://abs.example.com",
            },
            {
                text = _("API Key"),
                input = self.settings:readSetting("api_key") or "",
                hint = _("Bearer API key"),
            },
            {
                text = _("Library ID"),
                input = self.settings:readSetting("library_id") or "",
                hint = _("Optional preferred library"),
            },
            {
                text = _("Download dir"),
                input = self.settings:readSetting("download_dir") or "audiobooks",
                hint = _("Relative or absolute path"),
            },
            {
                text = _("Sync interval (sec)"),
                input = tostring(self.settings:readSetting("sync_interval") or 60),
                hint = "60",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        self.settings:saveSetting("base_url", fields[1])
                        self.settings:saveSetting("api_key", fields[2])
                        self.settings:saveSetting("library_id", fields[3])
                        self.settings:saveSetting("download_dir", fields[4])
                        self.settings:saveSetting("sync_interval", tonumber(fields[5]) or 60)
                        self.settings:flush()
                        UIManager:close(dialog)
                        UIManager:show(InfoMessage:new{
                            text = _("Audiobookshelf settings saved."),
                        })
                    end,
                },
            }
        }
    }
    UIManager:show(dialog)
end

function ABSAudio:testConnection()
    local ok, result = pcall(function()
        return self.client:listLibraries()
    end)

    UIManager:show(InfoMessage:new{
        text = ok and _("Connection successful.") or _("Connection failed: ") .. tostring(result),
    })
end

function ABSAudio:browseLibrary()
    local ok, items = pcall(function()
        return self.client:listAudiobooks()
    end)

    if not ok then
        UIManager:show(InfoMessage:new{
            text = _("Failed to load library: ") .. tostring(items),
        })
        return
    end

    local buttons = {}
    for _, item in ipairs(items or {}) do
        table.insert(buttons, {
            text = item.title,
            callback = function()
                self:showBookActions(item)
            end
        })
    end

    if #buttons == 0 then
        table.insert(buttons, {
            text = _("No audiobooks found"),
            callback = function() end
        })
    end

    local dlg = ButtonDialog:new{
        title = _("Audiobooks"),
        buttons = { buttons },
    }
    UIManager:show(dlg)
end

function ABSAudio:showBookActions(item)
    local dlg
    dlg = ButtonDialog:new{
        title = item.title,
        buttons = {
            {
                {
                    text = _("Download"),
                    callback = function()
                        UIManager:close(dlg)
                        self:downloadBook(item)
                    end,
                },
                {
                    text = _("Play"),
                    callback = function()
                        UIManager:close(dlg)
                        self:playBook(item)
                    end,
                },
            },
            {
                {
                    text = _("Sync progress"),
                    callback = function()
                        UIManager:close(dlg)
                        self.sync:syncItem(item.id, true)
                    end,
                },
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(dlg)
                    end,
                },
            }
        }
    }
    UIManager:show(dlg)
end

function ABSAudio:downloadBook(item)
    local ok, path_or_err = pcall(function()
        return self.downloads:downloadItem(item)
    end)

    UIManager:show(InfoMessage:new{
        text = ok and (_("Downloaded to: ") .. tostring(path_or_err))
               or (_("Download failed: ") .. tostring(path_or_err)),
    })
end

function ABSAudio:playBook(item)
    local local_item = self.state:getItem(item.id)
    if not local_item or not local_item.local_path then
        UIManager:show(InfoMessage:new{
            text = _("Book is not downloaded yet."),
        })
        return
    end

    local ok, err = pcall(function()
        self.player:play(local_item)
        self.sync:startTracking(item.id)
    end)

    if not ok then
        UIManager:show(InfoMessage:new{
            text = _("Playback failed: ") .. tostring(err),
        })
    end
end

function ABSAudio:resumeLastBook()
    local item = self.state:getLastPlayed()
    if not item then
        UIManager:show(InfoMessage:new{
            text = _("No last played book found."),
        })
        return
    end
    self.player:play(item)
    self.sync:startTracking(item.abs_item_id)
end

return ABSAudio
```

## abs_client.lua

This module wraps Audiobookshelf HTTP access. Use an API key with `Authorization: Bearer ...`, which is the auth method ABS documents for automation and scripts.[3]

```lua
local sockethttp = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")

local ABSClient = {}
ABSClient.__index = ABSClient

function ABSClient:new(settings)
    return setmetatable({
        settings = settings,
    }, self)
end

function ABSClient:getBaseUrl()
    local url = self.settings:readSetting("base_url") or ""
    return url:gsub("/$", "")
end

function ABSClient:getHeaders()
    local token = self.settings:readSetting("api_key") or ""
    return {
        ["Accept"] = "application/json",
        ["Authorization"] = "Bearer " .. token,
    }
end

function ABSClient:request(method, path)
    local response_body = {}
    local url = self:getBaseUrl() .. path

    local _, code, headers, status = sockethttp.request{
        url = url,
        method = method,
        headers = self:getHeaders(),
        sink = ltn12.sink.table(response_body),
    }

    local body = table.concat(response_body)
    if code ~= 200 then
        error("HTTP " .. tostring(code) .. ": " .. tostring(status) .. " " .. body)
    end

    return json.decode(body)
end

function ABSClient:listLibraries()
    return self:request("GET", "/api/libraries")
end

function ABSClient:listAudiobooks()
    local configured_id = self.settings:readSetting("library_id")
    if configured_id and configured_id ~= "" then
        local res = self:request("GET", "/api/libraries/" .. configured_id .. "/items")
        return self:normalizeItems(res and (res.results or res))
    end

    local libs = self:listLibraries()
    for _, lib in ipairs(libs.libraries or libs) do
        if lib.mediaType == "book" or lib.type == "book" then
            local res = self:request("GET", "/api/libraries/" .. lib.id .. "/items")
            return self:normalizeItems(res and (res.results or res))
        end
    end

    return {}
end

function ABSClient:getItem(item_id)
    return self:request("GET", "/api/items/" .. item_id)
end

function ABSClient:getDownloadUrl(item_id, track_index)
    track_index = track_index or 1
    return self:getBaseUrl() .. "/api/items/" .. item_id .. "/download/" .. tostring(track_index)
end

function ABSClient:updateProgress(item_id, current_time, duration, is_finished)
    local path = string.format(
        "/api/me/progress/%s?currentTime=%d&duration=%d&isFinished=%s",
        item_id,
        math.floor(current_time or 0),
        math.floor(duration or 0),
        is_finished and "1" or "0"
    )
    return self:request("PATCH", path)
end

function ABSClient:normalizeItems(items)
    local out = {}
    for _, item in ipairs(items or {}) do
        local media = item.media or {}
        table.insert(out, {
            id = item.id,
            title = media.metadata and media.metadata.title or item.title or "Untitled",
            author = media.metadata and media.metadata.authorName or "",
            duration = media.duration or 0,
            raw = item,
        })
    end
    return out
end

return ABSClient
```

## state.lua

This module keeps local manifest/state for downloaded items and progress, which is important because you do not want sync logic to depend only on live playback state. KOReader already exposes settings infrastructure suitable for this kind of persistence.[2][7]

```lua
local State = {}
State.__index = State

function State:new(settings)
    local o = {
        settings = settings,
        manifest = settings:readSetting("manifest") or {},
    }
    return setmetatable(o, self)
end

function State:save()
    self.settings:saveSetting("manifest", self.manifest)
    self.settings:flush()
end

function State:getItem(abs_item_id)
    return self.manifest[abs_item_id]
end

function State:upsertItem(abs_item_id, data)
    self.manifest[abs_item_id] = self.manifest[abs_item_id] or { abs_item_id = abs_item_id }
    for k, v in pairs(data) do
        self.manifest[abs_item_id][k] = v
    end
    self:save()
    return self.manifest[abs_item_id]
end

function State:setLastPlayed(abs_item_id)
    self.settings:saveSetting("last_played_id", abs_item_id)
    self.settings:flush()
end

function State:getLastPlayed()
    local id = self.settings:readSetting("last_played_id")
    if not id then return nil end
    return self.manifest[id]
end
end

return State
```

## downloads.lua

This module handles file download and manifest updates. For v1, keep it simple: one chosen audio file per item, downloaded to a configured folder.[8][3]

```lua
local sockethttp = require("socket.http")
local ltn12 = require("ltn12")
local lfs = require("lfs")

local Downloads = {}
Downloads.__index = Downloads

function Downloads:new(settings, client, state)
    return setmetatable({
        settings = settings,
        client = client,
        state = state,
    }, self)
end

function Downloads:getDownloadDir()
    local dir = self.settings:readSetting("download_dir") or "audiobooks"
    if dir:sub(1, 1) ~= "/" then
        dir = G_reader_settings:readSetting("home_dir") .. "/" .. dir
    end
    lfs.mkdir(dir)
    return dir
end

function Downloads:safeFilename(name)
    return (name:gsub("[/:*?\"<>|]", "_"))
end

function Downloads:downloadItem(item)
    local full = self.client:getItem(item.id)
    local media = full.media or {}
    local tracks = media.audioFiles or media.tracks or {}

    if not tracks[1] then
        error("No audio track found for item " .. tostring(item.id))
    end

    local filename = self:safeFilename(item.title) .. ".m4b"
    local target = self:getDownloadDir() .. "/" .. filename
    local file = assert(io.open(target, "wb"))

    local _, code, _, status = sockethttp.request{
        url = self.client:getDownloadUrl(item.id, 1),
        method = "GET",
        headers = self.client:getHeaders(),
        sink = ltn12.sink.file(file),
    }

    if code ~= 200 then
        error("Download failed: HTTP " .. tostring(code) .. " " .. tostring(status))
    end

    self.state:upsertItem(item.id, {
        abs_item_id = item.id,
        title = item.title,
        local_path = target,
        duration = item.duration or media.duration or 0,
        last_position = 0,
        finished = false,
    })

    return target
end

return Downloads
```

## player_adapter.lua

This is deliberately thin. In your real implementation, this should either call into existing audio-capable KOReader code or delegate to a fork of the audiobook plugin, because that is likely the least painful path on PocketBook.[9][10]

```lua
local PlayerAdapter = {}
PlayerAdapter.__index = PlayerAdapter

function PlayerAdapter:new(settings, state)
    return setmetatable({
        settings = settings,
        state = state,
        current = nil,
    }, self)
end

function PlayerAdapter:play(item)
    self.current = {
        abs_item_id = item.abs_item_id,
        local_path = item.local_path,
        started_at = os.time(),
        position = item.last_position or 0,
        duration = item.duration or 0,
        playing = true,
    }

    self.state:setLastPlayed(item.abs_item_id)

    -- TODO:
    -- Replace this with real playback integration.
    -- Best option is probably to hand off to an existing KOReader/PocketBook
    -- audio plugin rather than writing a player from scratch.
end

function PlayerAdapter:getCurrentState()
    if not self.current then return nil end
    return self.current
end

function PlayerAdapter:updatePosition(seconds)
    if self.current then
        self.current.position = seconds
    end
end

function PlayerAdapter:pause()
    if self.current then
        self.current.playing = false
    end
end

function PlayerAdapter:resume()
    if self.current then
        self.current.playing = true
    end
end

function PlayerAdapter:stop()
    if self.current then
        self.current.playing = false
    end
end

return PlayerAdapter
```

## progress_sync.lua

This module owns the sync policy. Audiobookshelf expects clients to report progress explicitly, so this module is where you decide when to flush state.[11][12]

```lua
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")

local ProgressSync = {}
ProgressSync.__index = ProgressSync

function ProgressSync:new(settings, client, state, player)
    return setmetatable({
        settings = settings,
        client = client,
        state = state,
        player = player,
        tracked_item_id = nil,
        last_sync_ts = 0,
    }, self)
end

function ProgressSync:startTracking(abs_item_id)
    self.tracked_item_id = abs_item_id
    self.last_sync_ts = 0
end

function ProgressSync:syncCurrent(show_message)
    local current = self.player:getCurrentState()
    if not current then
        if show_message then
            UIManager:show(InfoMessage:new{ text = "No active playback." })
        end
        return
    end
    self:syncItem(current.abs_item_id, show_message)
end

function ProgressSync:syncItem(abs_item_id, show_message)
    local current = self.player:getCurrentState()
    local item = self.state:getItem(abs_item_id)
    if not item then
        if show_message then
            UIManager:show(InfoMessage:new{ text = "No local state for item." })
        end
        return
    end

    local position = current and current.position or item.last_position or 0
    local duration = current and current.duration or item.duration or 0
    local finished = duration > 0 and position >= (duration * 0.98)

    self.client:updateProgress(abs_item_id, position, duration, finished)

    self.state:upsertItem(abs_item_id, {
        last_position = position,
        duration = duration,
        finished = finished,
        last_sync_at = os.time(),
    })

    if show_message then
        UIManager:show(InfoMessage:new{
            text = "Synced progress at " .. tostring(math.floor(position)) .. "s",
        })
    end
end

function ProgressSync:tick()
    local current = self.player:getCurrentState()
    if not current or not current.playing then
        return
    end

    local interval = tonumber(self.settings:readSetting("sync_interval") or 60)
    if os.time() - self.last_sync_ts >= interval then
        self:syncCurrent(false)
        self.last_sync_ts = os.time()
    end
end

return ProgressSync
```

## First things to change

Before trying to use this on hardware, I would change these parts first:

- Replace `socket.http`/JSON imports with whatever HTTP/JSON helpers are already used by the plugin example you fork, because KOReader packaging details can differ a bit by environment.[13][4]
- Verify the exact ABS endpoints you want against your server version, especially item listing, item detail, and progress update behavior.[3][8]
- Replace `player_adapter.lua` with a real integration against the existing audiobook plugin or another PocketBook-capable audio path.[10][9]
- Add one recurring timer/event hook so `progress_sync.lua:tick()` actually runs while playback is active.[4]

## Practical next step

The smartest implementation path is probably:

1. Fork an existing simple KOReader plugin for structure.[14][15]
2. Fork or inspect `audiobook.koplugin` for playback integration.[9]
3. Drop the ABS modules above into that structure.  
4. Get “test connection” and “download one book” working before touching progress sync.[8][3]

If you want, I can turn this into a **real starter package** next — meaning a zip with these files laid out properly, plus a small README and TODO markers for the PocketBook/audio integration points.

Sources
[1] KOPlugin.md https://gist.github.com/consoleaf/abbe8449377f1f6ef47b86d6c0d8873d
[2] Module luasettings https://koreader.rocks/doc/modules/luasettings.html
[3] Creating API Keys https://www.audiobookshelf.org/guides/api-keys/
[4] Development Guide - KOReader Documentation https://koreader.rocks/doc/topics/Development_guide.md.html
[5] DEVELOPING YOUR FIRST PLUGIN FOR KOREADER https://kindlemodshelf.me/koreaderplugindev
[6] Custom Plugin Not Loading in KOReader (Kindle) https://github.com/koreader/koreader/issues/13864
[7] Module docsettings https://koreader.rocks/doc/modules/docsettings.html
[8] Audiobookshelf API Reference https://api.audiobookshelf.org
[9] stradichenko/audiobook.koplugin: A plugin to give TTS- ... https://github.com/stradichenko/audiobook.koplugin
[10] Audiobook plugin for KOReader [v0.1.9]! With even more ... https://www.reddit.com/r/koreader/comments/1tjyxrq/audiobook_plugin_for_koreader_v019_with_even_more/
[11] Progress Sync between ABS and ThirdPartyClients like Shelfplayer · advplyr/audiobookshelf · Discussion #3538 https://github.com/advplyr/audiobookshelf/discussions/3538
[12] Update:API route for getting playback session and getting media ... https://git.laurivan.com/Mirrors/audiobookshelf/commit/bf928692d5b43ebbe147606b33c41445089e7e81?files=server%2Frouters
[13] koreader/plugins/docsettingtweak.koplugin/main.lua at ... https://github.com/koreader/koreader/blob/master/plugins/docsettingtweak.koplugin/main.lua
[14] GitHub - flip-rossi/readeck.koplugin: An unofficial KOReader plugin to add integration with your Readeck instance. https://github.com/flip-rossi/readeck.koplugin
[15] koreader-plugin-wattpad/README.md at main https://github.com/aoyn1xw/koreader-plugin-wattpad/blob/main/README.md
[16] Koreader can't find configuration.lua https://www.reddit.com/r/koreader/comments/1n5d8ni/koreader_cant_find_configurationlua/
[17] App Store Plugin For KOReader https://www.mobileread.com/forums/showthread.php?p=4553912
[18] KOReader AppStore - Discover & Install Community Plugins https://omer-faruq.github.io/appstore.koplugin/
[19] audiobookshelf_api - Dart API docs https://pub.dev/documentation/audiobookshelf_api/latest/
[20] plugins/calibre.koplugin/main.lua · master · koreader ... https://gitlab.com/koreader/koreader/-/blob/master/plugins/calibre.koplugin/main.lua
[21] KOREADER USER GUIDE https://koreader.rocks/koreader-user-guide.pdf
[22] Audiobookshelf ↔ Authentik: OIDC Integration Guide https://kabason.net/home-lab/application/audiobookshelfintegration.html
[23] Module util https://koreader.rocks/doc/modules/util.html
[24] KOReader Documentation https://koreader.rocks/doc/
