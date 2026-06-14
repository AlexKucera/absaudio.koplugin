-- Book detail view widget for absaudio.koplugin
-- Fullscreen scrollable view showing cover art, metadata, audio/ebook files,
-- and chapter list for a single library item.
--
-- Public API:
--   detail.show(data)
--     data: { item=..., on_download=fn, on_delete=fn }
--
-- When show() is called, it first tries to fetch expanded item details from ABS.
-- If that fails and the book is downloaded, it falls back to manifest data.
-- If that fails and the book is not downloaded, it shows an error.

local Blitbuffer = require("ffi/blitbuffer")
local BD = require("ui/bidi")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local Screen = Device.screen

local config = require("config")
local abs_logger = require("abs_logger")
local error_handler = require("error_handler")
local widget_helpers = require("absaudio/widget_helpers")
local progress_bar = require("absaudio/progress_bar")
local has_fs_helpers, fs_helpers = pcall(require, "absaudio/fs_helpers")

-- Try to load dependencies
local has_manifest, manifest = pcall(require, "manifest")
local has_api, api = pcall(require, "api")
local has_cover_cache, cover_cache = pcall(require, "absaudio/cover_cache")
local library_store = require("absaudio/library_store")
local has_navigator, nav = pcall(require, "absaudio/navigator")
local has_downloader, downloader = pcall(require, "absaudio/downloader")
local has_config, config = pcall(require, "config")
local has_progress, progress = pcall(require, "absaudio/download_progress")
local has_player, player = pcall(require, "absaudio/player")
local chapter_navigator = require("absaudio/chapter_navigator")
local ConfirmBox = require("ui/widget/confirmbox")

local detail = {}

------------------------------------------------------------------------
-- Public: prepare item data for rendering
-- Fetches expanded details from API, falls back to manifest,
-- or returns basic item data. Returns (data, nil) or (nil, error_info).
------------------------------------------------------------------------
function detail.prepare(item)
    -- Initialize cover cache (idempotent — safe to call from any entry path)
    if has_cover_cache and not cover_cache.isInitialized() then
        local DataStorage = require("datastorage")
        cover_cache.init(DataStorage:getSettingsDir() .. "/absaudio_covers")
    end

    -- Initialize manifest for potential fallback
    if has_manifest then
        manifest.init()
    end

    -- Try API first if configured
    if has_api and api.is_configured() then
        local ok, expanded = api.getItemDetails(item.id)
        if ok then
            return detail._mergeItemData(item, expanded), nil
        end
        abs_logger.warn("Failed to fetch item details via API, trying fallback")
    end

    -- Try manifest fallback
    if has_manifest then
        local book = manifest.getBook(item.id)
        if book then
            return detail._itemFromManifest(item, book), nil
        end
    end

    -- Return basic item data if it has enough info
    if item.title or item.media then
        abs_logger.info("prepare: returning basic item data (no API or manifest)")
        return item, nil
    end

    -- Nothing available
    return nil, { type = "network", message = _("Connect to WiFi to view book details.") }
end





------------------------------------------------------------------------
-- Helper: get duration from item
------------------------------------------------------------------------
local function get_item_duration(item)
    if item.media and item.media.duration then
        return item.media.duration
    end
    return item.duration or 0
end

------------------------------------------------------------------------
-- Helper: check if a format is the preferred format
------------------------------------------------------------------------
local function is_preferred_format(format)
    local preferred = config.get("preferred_format") or "m4b"
    return format and format:lower() == preferred:lower()
end

------------------------------------------------------------------------
-- Book Detail View
------------------------------------------------------------------------
local BookDetailView = FocusManager:extend{
    name = "absaudio_book_detail",
    is_editable = false,
    covers_fullscreen = true,
}

function BookDetailView:init()
    -- Store reference for tap callbacks
    self.detail_ref = self

    -- Back key closes the detail view
    if Device:hasKeys() then
        self.key_events = self.key_events or {}
        self.key_events.Close = { { Device.input.group.Back } }
    end

    -- Swipe down closes the detail view
    if Device:isTouchDevice() then
        self.ges_events = self.ges_events or {}
        self.ges_events.Swipe = {
            GestureRange:new{
                ges = "swipe",
                range = function() return self.dimen end,
            },
        }
    end

    local screen_size = Screen:getSize()
    self.dimen = screen_size
    self.screen_width = screen_size.w
    self.screen_height = screen_size.h
    self.content_width = self.screen_width - 2 * Size.padding.large

    -- Build content
    self.content_group = VerticalGroup:new{ align = "left" }

    -- Top padding
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.large })

    -- Back button header
    self:_addBackHeader()

    -- Cover art
    self:_addCoverArt()

    -- Now-playing controls (inserted between cover art and metadata)
    -- Only shown when audio is fully downloaded
    self.audio_download_state = self:_detectAudioState()
    if self.audio_download_state == "complete" and has_player then
        self:_initPlayer()
        self:_addNowPlaying()
    end

    -- Metadata section
    self:_addMetadata()

    -- Download status badge
    self:_addDownloadStatus()

    widget_helpers.addSeparator(self.content_group, self.content_width)

    -- Audio files section
    local audio_files = self.item.audioFiles or {}
    if #audio_files > 0 then
        self:_addAudioFiles(audio_files)
        widget_helpers.addSeparator(self.content_group, self.content_width)
    end

    -- Ebook/PDF files section
    -- ABS returns media.ebookFile (singular object), not ebookFiles (plural array)
    local ebook_files = {}
    if self.item.media and type(self.item.media.ebookFile) == "table" then
        local ef = self.item.media.ebookFile
        table.insert(ebook_files, {
            filename = ef.metadata and ef.metadata.filename or "ebook",
            format = ef.ebookFormat or (ef.metadata and ef.metadata.ext and ef.metadata.ext:gsub("^%.", "")) or "?",
            size = ef.metadata and ef.metadata.size or 0,
            ino = ef.ino,
        })
    elseif self.item.ebookFiles then
        ebook_files = self.item.ebookFiles
    end
    if #ebook_files > 0 then
        self:_addEbookFiles(ebook_files)
        widget_helpers.addSeparator(self.content_group, self.content_width)
    end

    -- Chapters section
    local chapters = {}
    if self.item.media and type(self.item.media.chapters) == "table" then
        chapters = self.item.media.chapters
    end
    if #chapters > 0 then
        self:_addChapters(chapters)
    end

    -- Bottom padding
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.large })

    -- Wrap in scrollable container
    self.scrollable = ScrollableContainer:new{
        dimen = Geom:new{
            w = self.screen_width,
            h = self.screen_height,
        },
        self.content_group,
    }

    -- Main frame — fullscreen, no borders
    self[1] = FrameContainer:new{
        width = self.screen_width,
        height = self.screen_height,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        self.scrollable,
    }
end

------------------------------------------------------------------------
-- Header with back button
------------------------------------------------------------------------
function BookDetailView:_addBackHeader()
    local back_text = TextWidget:new{
        text = "← " .. _("Back"),
        face = Font:getFace("cfont", 16),
        fgcolor = Blitbuffer.COLOR_BLUE,
    }

    local tap_container = InputContainer:new{
        dimen = Geom:new{
            w = self.content_width,
            h = back_text:getSize().h + Size.padding.default,
        },
    }
    tap_container.ges_events.TapBack = {
        GestureRange:new{
            ges = "tap",
            range = tap_container.dimen,
        },
    }
    tap_container.detail_ref = self.detail_ref
    function tap_container:onTapBack()
        self.detail_ref:onClose()
        return true
    end
    tap_container[1] = back_text
    table.insert(self.content_group, tap_container)
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })
end

------------------------------------------------------------------------
-- Cover art section
------------------------------------------------------------------------
function BookDetailView:_addCoverArt()
    local item_id = self.item.id
    local cover_path = nil

    -- Try to find cover: first check manifest (downloaded books), then cover cache
    if has_manifest then
        manifest.init()
        local book = manifest.getBook(item_id)
        if book and book.local_dir then
            local candidate = book.local_dir .. "/cover.jpg"
            local lfs_mod = _G.lfs or (pcall(require, "lfs") and require("lfs"))
            if lfs_mod and lfs_mod.attributes(candidate, "mode") == "file" then
                cover_path = candidate
            end
        end
    end

    if not cover_path and has_cover_cache then
        if cover_cache.hasCachedCover(item_id) then
            cover_path = cover_cache.getCoverPath(item_id)
        end
    end

    if cover_path then
        local cover_widget = ImageWidget:new{
            file = cover_path,
            width = self.content_width,
            height = math.min(200, self.screen_height * 0.25),
            scale_factor = 0,
            -- If the image fails to load, we show nothing (graceful degradation)
        }
        -- Center the cover image
        local cover_h = 200
        table.insert(self.content_group, CenterContainer:new{
            dimen = Geom:new{ w = self.content_width, h = cover_h },
            cover_widget,
        })
    else
        -- Placeholder for missing cover
        local placeholder = FrameContainer:new{
            width = self.content_width,
            height = 80,
            background = Blitbuffer.COLOR_LIGHT_GRAY,
            bordersize = 0,
            padding = 0,
            CenterContainer:new{
                dimen = Geom:new{ w = self.content_width, h = 80 },
                TextWidget:new{
                    text = _("No Cover"),
                    face = Font:getFace("cfont", 16),
                    fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                },
            },
        }
        table.insert(self.content_group, placeholder)
    end

    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.default })
end

------------------------------------------------------------------------
-- Detect audio download state from manifest (used early in init)
-- Returns "complete", "incomplete", or "none"
------------------------------------------------------------------------
function BookDetailView:_detectAudioState()
    local audio_state = "none"

    if has_manifest then
        local book = manifest.getBook(self.item.id)
        if book and book.files then
            for _, f in ipairs(book.files) do
                local ftype = f.type or "audio"
                if ftype == "audio" then
                    if audio_state == "none" then audio_state = f.status or "pending" end
                    if f.status ~= "complete" then audio_state = "incomplete" end
                end
            end
            if audio_state ~= "none" and audio_state ~= "incomplete" then
                audio_state = "complete"
            end
        end
    end

    return audio_state
end

------------------------------------------------------------------------
-- Metadata section: title, author, duration
------------------------------------------------------------------------

------------------------------------------------------------------------
-- Initialize player instance from manifest data
-- Called when audio is fully downloaded.
------------------------------------------------------------------------
function BookDetailView:_initPlayer()
    self.player = nil

    if not has_manifest then return end
    local book = manifest.getBook(self.item.id)
    if not book then return end

    self.player = player.create_from_manifest(book, self.item)
    -- Apply persisted playback speed (local-only preference; PRD §Playback Speed)
    if has_config and self.player then
        local saved_speed = config.get("playback_speed")
        if saved_speed and self.player.setPlaybackSpeed then
            self.player:setPlaybackSpeed(saved_speed)
        end
    end
end

------------------------------------------------------------------------
-- Now-playing controls section
-- Shows play/pause, skip buttons, progress bar, time display
-- Only called when audio is fully downloaded.
------------------------------------------------------------------------
function BookDetailView:_addNowPlaying()
    if not self.player then return end

    -- Chapters live on a single global timeline (ABS media.chapters).
    self.chapters = (self.item.media and self.item.media.chapters) or {}

    widget_helpers.addSeparator(self.content_group, self.content_width)

    -- Section header
    local header = TextWidget:new{
        text = "🎵 Now Playing",
        face = Font:getFace("cfont", 16),
        bold = true,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }
    table.insert(self.content_group, header)
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })

    -- Play/Pause button (large, centered)
    local play_btn = widget_helpers.makeTappableButton("▶", function()
        self.detail_ref:_onPlayPause()
    end, {
        face = Font:getFace("tfont", 28),
        fgcolor = Blitbuffer.COLOR_BLUE,
        width = self.content_width,
        tap_event_name = "TapPlayPause",
    })
    play_btn.detail_ref = self.detail_ref
    self.play_btn = play_btn  -- keep ref for play/pause icon toggle
    table.insert(self.content_group, CenterContainer:new{
        dimen = Geom:new{ w = self.content_width, h = play_btn.dimen.h },
        play_btn,
    })

    -- Progress bar (seekable via tap/drag)
    self.progress_bar = progress_bar.new({
        width = self.content_width,
        duration = self.player:getDuration(),
        position = self.player:getPosition(),
        on_seek = function(pos)
            self.detail_ref:_onSeekProgress(pos)
        end,
    })
    table.insert(self.content_group, self.progress_bar)
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })

    -- Current chapter name below the progress bar (US 27)
    if #self.chapters > 0 then
        local idx, ch = chapter_navigator.current(self.player:getPosition(), self.chapters)
        self.chapter_name_widget = TextWidget:new{
            text = string.format("Chapter %d: %s", idx, (ch and ch.title) or ""),
            face = Font:getFace("cfont", 14),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
        table.insert(self.content_group, CenterContainer:new{
            dimen = Geom:new{ w = self.content_width, h = 20 },
            self.chapter_name_widget,
        })
        table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })
    end

    -- Skip back / Time / Skip forward row
    local skip_row = HorizontalGroup:new{}

    -- Skip back 30s
    local skip_back_btn = widget_helpers.makeTappableButton("⏪", function()
        self.detail_ref:_onSkipBack()
    end, {
        face = Font:getFace("cfont", 20),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        width = 80,
        tap_event_name = "TapSkipBack",
    })
    skip_back_btn.detail_ref = self.detail_ref
    table.insert(skip_row, skip_back_btn)

    -- Time display (current / total)
    self.time_display_widget = TextWidget:new{
        text = "0:00 / " .. widget_helpers.format_time(self.player:getDuration()),
        face = Font:getFace("cfont", 14),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }
    table.insert(skip_row, self.time_display_widget)

    -- Skip forward 30s
    local skip_fwd_btn = widget_helpers.makeTappableButton("⏩", function()
        self.detail_ref:_onSkipForward()
    end, {
        face = Font:getFace("cfont", 20),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        width = 80,
        tap_event_name = "TapSkipFwd",
    })
    skip_fwd_btn.detail_ref = self.detail_ref
    table.insert(skip_row, skip_fwd_btn)

    table.insert(self.content_group, skip_row)
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })

    -- Playback speed button (cycles presets on tap; badge shows current speed)
    local speed_btn = widget_helpers.makeTappableButton(
        player.format_speed(self.player:getPlaybackSpeed()), function()
            self.detail_ref:_onSpeedCycle()
        end, {
            face = Font:getFace("cfont", 18),
            fgcolor = Blitbuffer.COLOR_BLUE,
            tap_event_name = "TapSpeedCycle",
        })
    speed_btn.detail_ref = self.detail_ref
    self.speed_btn = speed_btn  -- ref for badge updates

    -- Chapter skip (⏮/⏭) flanking the speed badge (US 29); when there are
    -- no chapters, the speed button is shown centered on its own.
    if #self.chapters > 0 then
        local nav_row = HorizontalGroup:new{}

        local ch_prev_btn = widget_helpers.makeTappableButton("⏮", function()
            self.detail_ref:_onChapterPrev()
        end, {
            face = Font:getFace("cfont", 20),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            width = 80,
            tap_event_name = "TapChapterPrev",
        })
        ch_prev_btn.detail_ref = self.detail_ref
        table.insert(nav_row, ch_prev_btn)

        -- Speed badge centered in the middle space
        table.insert(nav_row, CenterContainer:new{
            dimen = Geom:new{ w = math.max(self.content_width - 160, 80), h = 20 },
            speed_btn,
        })

        local ch_next_btn = widget_helpers.makeTappableButton("⏭", function()
            self.detail_ref:_onChapterNext()
        end, {
            face = Font:getFace("cfont", 20),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            width = 80,
            tap_event_name = "TapChapterNext",
        })
        ch_next_btn.detail_ref = self.detail_ref
        table.insert(nav_row, ch_next_btn)

        table.insert(self.content_group, nav_row)
    else
        table.insert(self.content_group, CenterContainer:new{
            dimen = Geom:new{ w = self.content_width, h = 20 },
            speed_btn,
        })
    end
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })
end

------------------------------------------------------------------------
-- Now-playing tap handlers
------------------------------------------------------------------------
function BookDetailView:_onPlayPause()
    if not self.player then return end

    local state = self.player:getState()
    if state == "stopped" or state == "paused" then
        self.player:play()
        self:_startPlaybackUpdates()
        self:_updatePlaybackDisplay()
    elseif state == "playing" then
        self.player:pause()
        self:_stopPlaybackUpdates()
        self:_updatePlaybackDisplay()
    end
end

function BookDetailView:_onSkipBack()
    if not self.player then return end

    local pos = self.player:getPosition()
    self.player:setPosition(pos - 30)
    self:_updatePlaybackDisplay()
end

function BookDetailView:_onSkipForward()
    if not self.player then return end

    local pos = self.player:getPosition()
    self.player:setPosition(pos + 30)
    self:_updatePlaybackDisplay()
end

function BookDetailView:_onSeekProgress(position)
    if not self.player then return end
    self.player:setPosition(position)
    self:_updatePlaybackDisplay()
end

------------------------------------------------------------------------
-- Chapter navigation (US 28, US 29) + playback speed (US 30).
-- All pure-logic via chapter_navigator / player.next_speed.
------------------------------------------------------------------------

-- Seek to the start of the previous chapter (smart restart: if deep in
-- the current chapter, restarts it instead; clamps to the first).
function BookDetailView:_onChapterPrev()
    if not self.player then return end
    if not self.chapters or #self.chapters == 0 then return end

    local idx = chapter_navigator.previous(self.player:getPosition(), self.chapters)
    if idx then self:_onSeekToChapter(idx) end
end

-- Seek to the start of the next chapter (no-op at the last chapter).
function BookDetailView:_onChapterNext()
    if not self.player then return end
    if not self.chapters or #self.chapters == 0 then return end

    local idx = chapter_navigator.next(self.player:getPosition(), self.chapters)
    if idx then self:_onSeekToChapter(idx) end
end

-- Tap-to-cycle playback speed; persists the preference locally (not synced).
function BookDetailView:_onSpeedCycle()
    if not self.player then return end

    local new_speed = player.next_speed(self.player:getPlaybackSpeed())
    self.player:setPlaybackSpeed(new_speed)

    -- Persist locally (PRD: speed preference is not synced to ABS)
    if has_config then
        config.set("playback_speed", new_speed)
        local settings = config.get_settings()
        if settings and settings.flush then settings:flush() end
    end

    -- Update the speed badge immediately (TextWidget caches its bitmap)
    if self.speed_btn and self.speed_btn[1] then
        self.speed_btn[1].text = player.format_speed(new_speed)
        self.speed_btn[1]:free()
    end
    self:_updatePlaybackDisplay()
end

-- Seek to a specific chapter's start (tapped from the chapter list).
function BookDetailView:_onSeekToChapter(chapter_idx)
    if not self.player then return end
    if not self.chapters or #self.chapters == 0 then return end

    self.player:setPosition(chapter_navigator.chapter_start(chapter_idx, self.chapters))
    self:_updatePlaybackDisplay()
end

-- Update progress bar and time display to reflect current player state
function BookDetailView:_updatePlaybackDisplay()
    if not self.player then return end

    local pos = self.player:getPosition()
    local dur = self.player:getDuration()
    local state = self.player:getState()

    if self.progress_bar then
        self.progress_bar:setPosition(pos)
    end
    if self.time_display_widget then
        self.time_display_widget.text = widget_helpers.format_time(pos) .. " / " .. widget_helpers.format_time(dur)
        self.time_display_widget:free()
    end
    -- Toggle play/pause button icon to reflect current state
    if self.play_btn and self.play_btn[1] then
        local icon = (state == "playing") and "⏸" or "▶"
        if self.play_btn[1].text ~= icon then
            self.play_btn[1].text = icon
            self.play_btn[1]:free()
        end
    end

    -- Refresh current-chapter label below the progress bar (US 27)
    if self.chapter_name_widget and self.chapters and #self.chapters > 0 then
        local idx, ch = chapter_navigator.current(pos, self.chapters)
        local label = string.format("Chapter %d: %s", idx, (ch and ch.title) or "")
        if self.chapter_name_widget.text ~= label then
            self.chapter_name_widget.text = label
            self.chapter_name_widget:free()
        end
    end

    local target = self.detail_ref or self
    -- Partial (non-flashing) refresh — a "full" refresh here would black-flash
    -- the entire e-ink screen every 0.5s update. "partial" repaints without the
    -- flash, matching the native audiobook player. ("full" is reserved for widget
    -- swaps/transitions.)
    UIManager:setDirty(target, "partial")
end
-- Periodic playback display updates (time + progress bar)
function BookDetailView:_startPlaybackUpdates()
    if self._playback_update_scheduled then return end
    self._playback_update_scheduled = true
    self:_scheduleNextPlaybackUpdate()
end
function BookDetailView:_stopPlaybackUpdates()
    self._playback_update_scheduled = false
end
function BookDetailView:_scheduleNextPlaybackUpdate()
    if not self._playback_update_scheduled then return end
    if not self.player or self.player:getState() ~= "playing" then
        self._playback_update_scheduled = false
        return
    end
    UIManager:scheduleIn(0.5, function()
        self:_updatePlaybackDisplay()
        -- Check for auto-finish
        if self.player:isFinished() then
            self:_stopPlaybackUpdates()
            self:_updatePlaybackDisplay()  -- final update showing finished state
            return
        end
        self:_scheduleNextPlaybackUpdate()
    end)
end
------------------------------------------------------------------------
-- Metadata section: title, author, duration
------------------------------------------------------------------------
function BookDetailView:_addMetadata()
    local title = library_store.getItemTitle(self.item)
    local author = library_store.getItemAuthor(self.item)
    local duration = get_item_duration(self.item)

    -- Title
    local title_widget = TextWidget:new{
        text = title,
        face = Font:getFace("tfont", 22),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
        max_width = self.content_width,
    }
    table.insert(self.content_group, title_widget)
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })

    -- Author
    if author and author ~= "" then
        local author_widget = TextWidget:new{
            text = author,
            face = Font:getFace("cfont", 16),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            max_width = self.content_width,
        }
        table.insert(self.content_group, author_widget)
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })

    -- Store initial state for dynamic updates
    self._last_player_state = "stopped"
    self._playback_update_scheduled = false
end

    -- Duration
    if duration and duration > 0 then
        local duration_widget = TextWidget:new{
            text = "⏱ " .. widget_helpers.format_duration(duration),
            face = Font:getFace("cfont", 14),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
        table.insert(self.content_group, duration_widget)
    end

    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.default })
end

------------------------------------------------------------------------
-- Download status badge and action buttons
-- Per-type status tracking:
--   Audio and ebook have independent download states.
--   Shows status badge + action buttons per type.
------------------------------------------------------------------------
function BookDetailView:_addDownloadStatus()
    local item_id = self.item.id
    local audio_state = "none"  -- "none", "complete", "incomplete", "partial"
    local ebook_state = "none"

    if has_manifest then
        local book = manifest.getBook(item_id)
        if book and book.files then
            for _, f in ipairs(book.files) do
                local ftype = f.type or "audio"  -- backward compat
                if ftype == "audio" then
                    if audio_state == "none" then audio_state = f.status or "pending" end
                    if f.status ~= "complete" then audio_state = "incomplete" end
                elseif ftype == "ebook" then
                    if f.status == "complete" then ebook_state = "complete" end
                    if f.status == "partial" or f.status == "pending" then ebook_state = "incomplete" end
                end
            end
            -- Refine audio_state
            if audio_state ~= "none" and audio_state ~= "incomplete" then
                audio_state = "complete"
            end
        end
    end

    -- Check if there ARE audio files (from item data or manifest)
    -- Show audio status if: (1) item has audioFiles, OR (2) manifest has audio files
    -- If neither but we're on a detail page for an audiobook, show "not downloaded" state
    local has_audio_files = (self.item.audioFiles and #self.item.audioFiles > 0)
        or (self.item.media and type(self.item.media.audioFiles) == "table" and #self.item.media.audioFiles > 0)
        or audio_state ~= "none"  -- manifest has audio-type files

    -- If item has duration (audiobook) but no audioFiles in data,
    -- still show the audio download section
    if not has_audio_files and (self.item.media and self.item.media.duration
        and self.item.media.duration > 0) then
        has_audio_files = true
        audio_state = "none"  -- not downloaded
    end

    -- Audio download status badge
    if has_audio_files then
        self:_addAudioDownloadStatus(audio_state)
    end
end

------------------------------------------------------------------------
------------------------------------------------------------------------
-- Audio download status sub-section
------------------------------------------------------------------------
function BookDetailView:_addAudioDownloadStatus(audio_state)
    local item_id = self.item.id

    if audio_state == "complete" then
        -- Audio fully downloaded
        local badge = TextWidget:new{
            text = "✓ " .. _("Audio downloaded"),
            face = Font:getFace("cfont", 14),
            fgcolor = Blitbuffer.COLOR_DARK_GREEN,
        }
        table.insert(self.content_group, badge)

        -- Show Delete button (self-contained _onDeleteBook)
        table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })
        local delete_btn = TextWidget:new{
            text = _("🗑 Delete audio"),
            face = Font:getFace("cfont", 16),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
        local tap_container = InputContainer:new{
            dimen = Geom:new{
                w = self.content_width,
                h = delete_btn:getSize().h + Size.padding.default,
            },
        }
        tap_container.ges_events.TapDelete = {
            GestureRange:new{
                ges = "tap",
                range = tap_container.dimen,
            },
        }
        tap_container.detail_ref = self.detail_ref
        tap_container.captured_item = self.item
        function tap_container:onTapDelete()
            self.detail_ref:_onDeleteBook(self.captured_item, false)
            return true
        end
        tap_container[1] = delete_btn
        table.insert(self.content_group, tap_container)

    elseif audio_state == "incomplete" then
        -- Audio incomplete
        local badge = TextWidget:new{
            text = "⚠ " .. _("Audio download incomplete"),
            face = Font:getFace("cfont", 14),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
        table.insert(self.content_group, badge)

        -- Show Resume button (self-contained _onDownloadBook)
        table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })
        local resume_btn = TextWidget:new{
            text = _("⬇ Resume audio"),
            face = Font:getFace("cfont", 16),
            fgcolor = Blitbuffer.COLOR_BLUE,
        }
        local tap_container = InputContainer:new{
            dimen = Geom:new{
                w = self.content_width,
                h = resume_btn:getSize().h + Size.padding.default,
            },
        }
        tap_container.ges_events.TapResume = {
            GestureRange:new{
                ges = "tap",
                range = tap_container.dimen,
            },
        }
        tap_container.detail_ref = self.detail_ref
        tap_container.captured_item = self.item
        function tap_container:onTapResume()
            self.detail_ref:_onDownloadBook(self.captured_item)
            return true
        end
        tap_container[1] = resume_btn
        table.insert(self.content_group, tap_container)

        -- Show Delete button (self-contained _onDeleteBook)
        table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })
        local delete_btn = TextWidget:new{
            text = _("🗑 Delete audio"),
            face = Font:getFace("cfont", 16),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
        local tap_container = InputContainer:new{
            dimen = Geom:new{
                w = self.content_width,
                h = delete_btn:getSize().h + Size.padding.default,
            },
        }
        tap_container.ges_events.TapDelete = {
            GestureRange:new{
                ges = "tap",
                range = tap_container.dimen,
            },
        }
        tap_container.detail_ref = self.detail_ref
        tap_container.captured_item = self.item
        function tap_container:onTapDelete()
            self.detail_ref:_onDeleteBook(self.captured_item, false)
            return true
        end
        tap_container[1] = delete_btn
        table.insert(self.content_group, tap_container)

    else
        -- Audio not downloaded
        local badge = TextWidget:new{
            text = _("Audio not downloaded"),
            face = Font:getFace("cfont", 14),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
        table.insert(self.content_group, badge)

        -- Show download button (self-contained _onDownloadBook)
        table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })
        local download_btn = TextWidget:new{
            text = _("⬇ Download audio"),
            face = Font:getFace("cfont", 16),
            fgcolor = Blitbuffer.COLOR_BLUE,
        }
        local tap_container = InputContainer:new{
            dimen = Geom:new{
                w = self.content_width,
                h = download_btn:getSize().h + Size.padding.default,
            },
        }
        tap_container.ges_events.TapDownload = {
            GestureRange:new{
                ges = "tap",
                range = tap_container.dimen,
            },
        }
        tap_container.detail_ref = self.detail_ref
        tap_container.captured_item = self.item
        function tap_container:onTapDownload()
            self.detail_ref:_onDownloadBook(self.captured_item)
            return true
        end
        tap_container[1] = download_btn
        table.insert(self.content_group, tap_container)
    end

    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })
end


------------------------------------------------------------------------
-- Section header helper
------------------------------------------------------------------------
function BookDetailView:_addSectionHeader(text)
    local header = TextWidget:new{
        text = text,
        face = Font:getFace("cfont", 18),
        bold = true,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }
    table.insert(self.content_group, header)
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })
end

------------------------------------------------------------------------
-- Audio files section
------------------------------------------------------------------------
function BookDetailView:_addAudioFiles(audio_files)
    self:_addSectionHeader(_("Audio Files"))

    local preferred = config.get("preferred_format") or "m4b"

    -- Sort: preferred format files first
    local sorted_files = {}
    for _, f in ipairs(audio_files) do
        table.insert(sorted_files, f)
    end
    table.sort(sorted_files, function(a, b)
        local a_pref = (a.format and a.format:lower() == preferred:lower()) and 0 or 1
        local b_pref = (b.format and b.format:lower() == preferred:lower()) and 0 or 1
        if a_pref ~= b_pref then return a_pref < b_pref end
        return (a.filename or "") < (b.filename or "")
    end)

    for _, file in ipairs(sorted_files) do
        local format_str = string.upper(file.format or "???")
        local is_preferred = is_preferred_format(file.format)
        local badge_color = is_preferred and Blitbuffer.COLOR_DARK_GREEN or Blitbuffer.COLOR_DARK_GRAY
        local badge_prefix = is_preferred and "★ " or ""

        local file_text = string.format("  %s%s  %s  %s",
            badge_prefix,
            format_str,
            file.filename or _("Unknown file"),
            widget_helpers.format_file_size(file.size))

        local file_widget = TextWidget:new{
            text = file_text,
            face = Font:getFace("cfont", 14),
            fgcolor = badge_color,
            max_width = self.content_width,
        }
        table.insert(self.content_group, file_widget)
        table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })
    end

    -- Show note about preferred format
    local note = TextWidget:new{
        text = string.format(_("★ = preferred format (%s)"), preferred),
        face = Font:getFace("cfont", 12),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }
    table.insert(self.content_group, note)
    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.default })
end

------------------------------------------------------------------------
-- Ebook/PDF files section
------------------------------------------------------------------------
function BookDetailView:_addEbookFiles(ebook_files)
    self:_addSectionHeader(_("Ebook / PDF Files"))

    -- Check ebook download status from manifest
    local ebook_status_map = {}  -- ino -> status
    if has_manifest then
        local book = manifest.getBook(self.item.id)
        if book and book.files then
            for _, f in ipairs(book.files) do
                if f.type == "ebook" then
                    ebook_status_map[f.ino] = f.status
                end
            end
        end
    end

    local all_ebooks_complete = true
    local any_ebook_incomplete = false

    for _, file in ipairs(ebook_files) do
        local format_str = string.upper(file.format or "???")
        local status = ebook_status_map[file.ino]
        local status_str = ""
        if status == "complete" then
            status_str = " ✓"
        elseif status == "partial" then
            status_str = " ⚠"
            any_ebook_incomplete = true
            all_ebooks_complete = false
        else
            all_ebooks_complete = false
        end

        local file_text = string.format("  %s  %s  %s%s",
            format_str,
            file.filename or _("Unknown file"),
            widget_helpers.format_file_size(file.size),
            status_str)

        local file_widget = TextWidget:new{
            text = file_text,
            face = Font:getFace("cfont", 14),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            max_width = self.content_width,
        }
        table.insert(self.content_group, file_widget)
        table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })
    end

    -- Ebook download/delete buttons
    if all_ebooks_complete and not any_ebook_incomplete then
        -- All ebooks downloaded — show Open + Delete buttons
        -- Resolve ebook file path from manifest
        local ebook_path = nil
        if has_manifest then
            local book = manifest.getBook(self.item.id)
            if book and book.local_dir then
                for _, f in ipairs(book.files or {}) do
                    if f.type == "ebook" and f.status == "complete" then
                        ebook_path = book.local_dir .. "/" .. f.filename
                        break
                    end
                end
            end
        end

        -- Open Ebook button (always when path exists - self-contained _onOpenEbook)
        if ebook_path then
            table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })
            local open_btn = TextWidget:new{
                text = _("Open Ebook"),
                face = Font:getFace("cfont", 16),
                fgcolor = Blitbuffer.COLOR_BLUE,
            }
            local open_container = InputContainer:new{
                dimen = Geom:new{
                    w = self.content_width,
                    h = open_btn:getSize().h + Size.padding.default,
                },
            }
            open_container.ges_events.TapOpenEbook = {
                GestureRange:new{
                    ges = "tap",
                    range = open_container.dimen,
                },
            }
            open_container.detail_ref = self.detail_ref
            open_container.captured_ebook_path = ebook_path
            function open_container:onTapOpenEbook()
                self.detail_ref:_onOpenEbook(self.captured_ebook_path)
                return true
            end
            open_container[1] = open_btn
            table.insert(self.content_group, open_container)
        end
        -- Delete ebook button (self-contained _onDeleteBook)
        table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })
        local delete_btn = TextWidget:new{
            text = _("Delete ebook"),
            face = Font:getFace("cfont", 16),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
        local tap_container = InputContainer:new{
            dimen = Geom:new{
                w = self.content_width,
                h = delete_btn:getSize().h + Size.padding.default,
            },
        }
        tap_container.ges_events.TapDeleteEbook = {
            GestureRange:new{
                ges = "tap",
                range = tap_container.dimen,
            },
        }
        tap_container.detail_ref = self.detail_ref
        tap_container.captured_item = self.item
        function tap_container:onTapDeleteEbook()
            self.detail_ref:_onDeleteBook(self.captured_item, true)
            return true
        end
        tap_container[1] = delete_btn
        table.insert(self.content_group, tap_container)
    else
        -- Not all ebooks downloaded — show download/resume button (self-contained _onDownloadBook)
        table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })
        local btn_label = any_ebook_incomplete and _("⬇ Resume ebook") or _("⬇ Download Ebook")
        local ebook_btn = TextWidget:new{
            text = btn_label,
            face = Font:getFace("cfont", 16),
            fgcolor = Blitbuffer.COLOR_BLUE,
        }
        local tap_container = InputContainer:new{
            dimen = Geom:new{
                w = self.content_width,
                h = ebook_btn:getSize().h + Size.padding.default,
            },
        }
        tap_container.ges_events.TapEbook = {
            GestureRange:new{
                ges = "tap",
                range = tap_container.dimen,
            },
        }
        tap_container.detail_ref = self.detail_ref
        tap_container.captured_item = self.item
        function tap_container:onTapEbook()
            self.detail_ref:_onDownloadBook(self.captured_item, true)
            return true
        end
        tap_container[1] = ebook_btn
        table.insert(self.content_group, tap_container)
    end

    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.default })
end
------------------------------------------------------------------------
function BookDetailView:_addChapters(chapters)
    self:_addSectionHeader(_("Chapters"))

    for i, chapter in ipairs(chapters) do
        local chapter_title = chapter.title or string.format(_("Chapter %d"), i)
        local time_range = widget_helpers.format_time(chapter.start or 0) .. " → " .. widget_helpers.format_time(chapter["end"] or 0)

        local chapter_text = string.format("  %s\n    %s", chapter_title, time_range)

        local chapter_widget = TextBoxWidget:new{
            text = chapter_text,
            face = Font:getFace("cfont", 14),
            width = self.content_width,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }

        -- Wrap in tappable container (for future seek-to-chapter)
        local tap_container = InputContainer:new{
            dimen = Geom:new{
                w = self.content_width,
                h = chapter_widget:getSize().h,
            },
        }
        tap_container.ges_events.TapChapter = {
            GestureRange:new{
                ges = "tap",
                range = tap_container.dimen,
            },
        }
        tap_container.detail_ref = self.detail_ref
        tap_container.chapter = chapter
        tap_container.chapter_idx = i
        function tap_container:onTapChapter()
            -- Seek playback to this chapter's start position (US 28)
            self.detail_ref:_onSeekToChapter(self.chapter_idx)
            return true
        end
        tap_container[1] = chapter_widget
        table.insert(self.content_group, tap_container)
        table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.small })
    end

    table.insert(self.content_group, VerticalSpan:new{ width = Size.padding.default })
end

------------------------------------------------------------------------
-- Download handler — self-contained on BookDetailView
-- Mirrors library_browser:_onDownloadBook but uses self directly (no self_ref).
------------------------------------------------------------------------
function BookDetailView:_onDownloadBook(item, ebook_only)
    abs_logger.info("Detail download requested: " .. (item.title or item.id)
        .. (ebook_only and " (ebook)" or ""))
    if not has_manifest or not has_config or not has_downloader then
        UIManager:show(InfoMessage:new{ text = _("Download not available") })
        return
    end
    manifest.init()

    local result = nil

    if ebook_only then
        local ok, ebook_result = downloader.prepare_ebook_download(item, manifest, config)
        if not ok then
            UIManager:show(InfoMessage:new{
                text = _("No ebook files found for this book."),
                timeout = 3,
            })
            return
        end
        result = ebook_result
    else
        local existing_entry = manifest.getBook(item.id)
        if existing_entry and manifest.hasIncompleteFiles(item.id) then
            abs_logger.info("Resuming incomplete download: " .. (item.title or item.id))
            result = existing_entry
        else
            local ok, prepare_result = downloader.prepare_download(item, manifest, config)
            if not ok then
                if prepare_result == "already_downloaded" then
                    UIManager:show(ConfirmBox:new{
                        text = _("Already downloaded. Re-download?"),
                        ok_text = _("Re-download"),
                        ok_callback = function()
                            local lfs_mod = _G.lfs or require("lfs")
                            local fs_del = {
                                delete_file = function(path) os.remove(path) end,
                                delete_dir = function(path) lfs_mod.rmdir(path) end,
                            }
                            downloader.delete_book(item.id, manifest, fs_del)
                            self:_onDownloadBook(item)
                        end,
                    })
                else
                    UIManager:show(InfoMessage:new{ text = _("No audio files found for this book.") })
                end
                return
            end
            result = prepare_result
        end
    end

    -- Calculate already-downloaded bytes (for resume progress display)
    local function get_existing_bytes(entry, fs_impl)
        local existing = 0
        for _, f in ipairs(entry.files) do
            if f.status == "partial" then
                local size = fs_impl.get_file_size(entry.local_dir .. "/" .. f.filename)
                if size then existing = existing + size end
            end
        end
        return existing
    end

    local lfs_for_calc = _G.lfs or require("lfs")
    local fs_calc = {
        get_file_size = function(path)
            local attr = lfs_for_calc.attributes(path)
            return attr and attr.size or nil
        end,
    }

    -- Free space check (only count remaining bytes for resume)
    local total_sizes = downloader.calculate_download_size(result.files)
    local already_on_disk = get_existing_bytes(result, fs_calc)
    local needed = total_sizes - already_on_disk
    if needed > 0 then
        local dl_dir = config.get("download_dir") or "/tmp"
        local free_bytes = downloader.get_free_space(dl_dir)
        if free_bytes and not downloader.check_free_space(needed, free_bytes) then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Insufficient disk space. Need %s, have %s."),
                    widget_helpers.format_bytes(needed), widget_helpers.format_bytes(free_bytes)),
                timeout = 5,
            })
            return
        end
    end
    -- Download state + progress widget
    local state = downloader.create_download_state()
    state.start_time = os.time()
    state.total_files = #result.files
    state.total_bytes = total_sizes
    state.bytes_downloaded = already_on_disk  -- resume-aware progress

    if has_progress then
        progress.show({
            state = state,
            on_cancel = function() state:cancel() end,
        })
    end
    -- Build filesystem deps
    local lfs_mod = _G.lfs or require("lfs")
    local deps = {
        manifest = manifest,
        api = require("api"),
        fs = {
            mkdir = function(path)
                if has_fs_helpers then
                    fs_helpers.mkdir_p(path)
                end
            end,
            open = function(path, mode) return io.open(path, mode) end,
            get_file_size = function(path)
                local attr = lfs_mod.attributes(path)
                return attr and attr.size or nil
            end,
        },
        state = state,
    }

    local files_to_download = downloader.select_files_to_download(result.files)
    local entry = result

    local function schedule_next(idx)
        if idx > #files_to_download or state:is_cancelled() then
            if has_progress then progress.close() end
            local msg = state:is_cancelled()
                and _("Download cancelled.")
                or _("Download complete!")
            UIManager:show(InfoMessage:new{ text = msg, timeout = 3 })
            if has_navigator then
                nav.pop()
                UIManager:scheduleIn(0.1, function()
                    nav.push("detail", { item = item })
                end)
            end
            return
        end
        local file = files_to_download[idx]
        state.current_file = idx

        local handle, err = downloader.start_chunked_download(entry, file, deps)
        if not handle then
            if has_progress then progress.close() end
            UIManager:show(InfoMessage:new{
                text = _("Download failed: ") .. tostring(err),
                timeout = 5,
            })
            return
        end
        local function pump()
            if state:is_cancelled() then
                handle:cancel()
                handle:finalize()
                if has_progress then progress.close() end
                UIManager:show(InfoMessage:new{ text = _("Download cancelled."), timeout = 3 })
                if has_navigator then
                    nav.pop()
                    UIManager:scheduleIn(0.1, function()
                        nav.push("detail", { item = item })
                    end)
                end
                return
            end
            local still_running = handle:pump()
            -- [DLDBG] wall-clock timestamp per pump fire (temp diagnostic).
            -- Cleanup: grep -rn DLDBG. Pattern reveals event-loop starvation:
            --   ~0.05s gaps  = timers self-driving (NOT suspend)
            --   burst + multi-sec gap = PocketBook auto-suspend starving pump
            do
                local sok, socket = pcall(require, "socket")
                local now = (sok and socket.gettime and socket.gettime()) or os.time()
                local _t = type
                abs_logger.info(string.format(
                    "[DLDBG] pump fire t=%.3f bytes=%d state_bytes=%s",
                    now, (file.size or 0), tostring(state.bytes_downloaded)))
            end
            if has_progress then progress.update(state) end

            if still_running then
                UIManager:scheduleIn(0.05, pump)
            else
                local ok_final, reason = handle:finalize()
                if not ok_final then
                    if has_progress then progress.close() end
                    UIManager:show(InfoMessage:new{
                        text = _("Download failed: ") .. tostring(reason),
                        timeout = 5,
                    })
                    return
                end
                UIManager:scheduleIn(0.05, function()
                    schedule_next(idx + 1)
                end)
            end
        end
        UIManager:scheduleIn(0.05, pump)
    end
    UIManager:scheduleIn(0.1, function() schedule_next(1) end)
end

------------------------------------------------------------------------
-- Delete handler — self-contained on BookDetailView
-- Mirrors library_browser:_onDeleteBook but uses self directly (no self_ref).
------------------------------------------------------------------------
function BookDetailView:_onDeleteBook(item, ebook_only)
    abs_logger.info("Detail delete requested: " .. (item.title or item.id)
        .. (ebook_only and " (ebook only)" or ""))
    if not has_manifest or not has_downloader then
        UIManager:show(InfoMessage:new{ text = _("Delete not available") })
        return
    end
    manifest.init()

    if ebook_only then
        self:_onDeleteEbookOnly(item)
        return
    end

    UIManager:show(ConfirmBox:new{
        text = _("Delete this downloaded book?"),
        ok_text = _("Delete"),
        ok_callback = function()
            local lfs_mod = _G.lfs or require("lfs")
            local fs = {
                delete_file = function(path) os.remove(path) end,
                delete_dir = function(path) lfs_mod.rmdir(path) end,
            }
            local ok = downloader.delete_book(item.id, manifest, fs)
            if ok then
                UIManager:show(InfoMessage:new{ text = _("Book deleted successfully."), timeout = 3 })
            else
                UIManager:show(InfoMessage:new{ text = _("Book not found in downloads."), timeout = 3 })
            end
            -- Refresh detail view by popping and re-pushing (no callbacks needed)
            if has_navigator then
                nav.pop()
                UIManager:scheduleIn(0.1, function()
                    nav.push("detail", { item = item })
                end)
            end
        end,
    })
end

------------------------------------------------------------------------
-- Ebook-only delete helper — removes ebook files, preserves audio
------------------------------------------------------------------------
function BookDetailView:_onDeleteEbookOnly(item)
    local entry = manifest.getBook(item.id)
    if not entry or not entry.files then return end

    local lfs_mod = _G.lfs or require("lfs")

    -- Delete ebook files from disk and remove from manifest entry
    local remaining_files = {}
    for _, f in ipairs(entry.files) do
        if f.type == "ebook" then
            local path = entry.local_dir .. "/" .. f.filename
            os.remove(path)
        else
            table.insert(remaining_files, f)
        end
    end
    entry.files = remaining_files
    manifest.addBook(entry)
    UIManager:show(InfoMessage:new{ text = _("Ebook deleted."), timeout = 2 })

    -- Refresh detail view (no callbacks needed)
    if has_navigator then
        nav.pop()
        UIManager:scheduleIn(0.1, function()
            nav.push("detail", { item = item })
        end)
    end
end

------------------------------------------------------------------------
-- Open ebook in KOReader's ReaderUI
-- Self-contained: no callback needed from caller.
------------------------------------------------------------------------
function BookDetailView:_onOpenEbook(filepath)
    abs_logger.info("Detail opening ebook: " .. tostring(filepath))
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(filepath)
end
------------------------------------------------------------------------
-- Close / navigation
------------------------------------------------------------------------
function BookDetailView:onClose()
    if has_navigator then
        nav.pop()              -- nav.pop() owns UIManager:close(self)
    else
        UIManager:close(self)   -- standalone fallback
    end
    return true
end

function BookDetailView:onSwipe(arg, ges_ev)
    if ges_ev.direction == "south" then
        self:onClose()
    end
    return true
end

------------------------------------------------------------------------
-- Public: show book detail view
-- Uses prepare() for data fetching, then renders the view.
-- When API is configured, fetches async via scheduleIn.
-- When offline, calls prepare() synchronously.
------------------------------------------------------------------------
function detail.show(data)
    data = data or {}
    local item = data.item
    if not item then return nil end
    local on_download = data.on_download
    local on_delete = data.on_delete
    local on_open_ebook = data.on_open_ebook
    abs_logger.info("Showing book detail: " .. (item.title or item.id or "unknown"))

    -- Initialize manifest for potential fallback
    if has_manifest then
        manifest.init()
    end

    -- Async path: show loading indicator, call prepare in scheduleIn
    if has_api and api.is_configured() then
        local loading = InfoMessage:new{
            text = _("Loading book details…"),
            timeout = 0,  -- no auto-dismiss
        }
        UIManager:show(loading)

        UIManager:scheduleIn(0.1, function()
            UIManager:close(loading)
            local prepared, err = detail.prepare(item)
            if prepared then
                local view = detail._renderView(prepared, on_download, on_delete, on_open_ebook)
                if has_navigator then
                    nav._setCurrent(view)
                end
            else
                error_handler.show(err.type or "network", err.message or _("Unable to load book details."))
                if has_navigator then
                    nav.pop()
                end
            end
        end)
        return true  -- async in progress; _setCurrent updates nav later
    else
        -- Synchronous path
        local prepared, err = detail.prepare(item)
        if prepared then
            return detail._renderView(prepared, on_download, on_delete, on_open_ebook)
        else
            error_handler.show(err.type or "network", err.message or _("Unable to load book details."))
            return nil
        end
    end
end

------------------------------------------------------------------------
-- Render the detail view widget
------------------------------------------------------------------------
function detail._renderView(item, on_download, on_delete, on_open_ebook)
    local view = BookDetailView:new{
        item = item,
        on_download = on_download,
        on_delete = on_delete,
        on_open_ebook = on_open_ebook,
    }
    UIManager:show(view)
    UIManager:setDirty(view, "full")
    return view
end

------------------------------------------------------------------------
-- Merge expanded API data into the basic item
-- Expanded data from getItemDetails has audioFiles, ebookFiles,
-- and media.chapters at the top level.
------------------------------------------------------------------------
function detail._mergeItemData(base_item, expanded)
    local merged = {}
    for k, v in pairs(base_item) do
        merged[k] = v
    end
    for k, v in pairs(expanded) do
        merged[k] = v
    end
    return merged
end

------------------------------------------------------------------------
-- Build a displayable item from manifest data
-- (for offline viewing of downloaded books)
------------------------------------------------------------------------
function detail._itemFromManifest(item, book)
    -- Reconstruct ebookFile from manifest if ebook files exist
    local ebookFile = nil
    if book.files then
        for _, f in ipairs(book.files) do
            if f.type == "ebook" then
                ebookFile = {
                    ino = f.ino,
                    metadata = {
                        filename = f.filename,
                        ext = "." .. (f.filename:match("%.(%w+)$") or ""),
                        size = f.size,
                    },
                    ebookFormat = f.filename:match("%.(%w+)$") or "",
                }
                break  -- use first ebook file
            end
        end
    end

    return {
        id = item.id or book.abs_item_id,
        title = book.title or item.title,
        author = book.author or "",
        mediaType = item.mediaType or "book",
        addedAt = item.addedAt,
        media = {
            duration = book.duration,
            metadata = {
                title = book.title,
                authorName = book.author,
            },
            chapters = book.chapters or {},
            ebookFile = ebookFile,
        },
        audioFiles = {},  -- Manifest doesn't track ABS file objects
        ebookFiles = {},  -- Manifest doesn't track ABS file objects
        -- Manifest tracks local files, not ABS audioFiles
    }
end

return detail
