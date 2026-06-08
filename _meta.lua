-- _meta.lua — KOReader plugin descriptor for absaudio.koplugin
-- This file tells KOReader how to discover and load the plugin.
-- The plugin name is derived from the directory name (absaudio).
--
-- Convention: must be at the root of the .koplugin directory.

local _ = require("gettext")

return {
    fullname = _("ABS Audio"),
    description = _([[Audiobookshelf audio player — browse, download, and play audiobooks from your ABS server with progress sync.]]),
}
