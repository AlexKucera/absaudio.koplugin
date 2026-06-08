-- Dashboard widget for absaudio.koplugin
-- Root view with 4 sections: Resume Last Book, Downloaded Books, Browse Library, Settings
-- This is a placeholder shell for Slice 1 — full implementation in later slices.
--
-- Public API:
--   dashboard.show()  — display the dashboard

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local dashboard = {}

--- Show the dashboard (placeholder for Slice 1)
function dashboard.show()
    UIManager:show(InfoMessage:new{
        text = _([[ABS Audio

• Resume Last Book
• Downloaded Books
• Browse Library
• Settings

No audiobooks downloaded yet. Use Settings to configure your server.]]),
        timeout = 0, -- stays until dismissed
    })
end

return dashboard
