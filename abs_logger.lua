-- Logger wrapper for absaudio.koplugin
-- Wraps KOReader's built-in logger with configurable verbosity and [ABS] prefix.
--
-- Public API:
--   logger.set_level(level)    -- set minimum log level: "verbose", "info", "warn"
--   logger.get_level()         -- get current log level
--   logger.should_log(level)   -- check if a message at this level would be logged
--   logger.verbose(msg)        -- log at verbose level (maps to KOReader dbg)
--   logger.info(msg)           -- log at info level
--   logger.warn(msg)           -- log at warn level

local koreader_logger = require("logger")

local logger = {}

-- Log level priority: lower = more verbose
local LEVEL_PRIORITY = {
    verbose = 1,
    info = 2,
    warn = 3,
}

local current_level = "verbose"
local PREFIX = "[ABS] "

--- Set the minimum log level
-- @param level string  "verbose", "info", or "warn"
function logger.set_level(level)
    if LEVEL_PRIORITY[level] then
        current_level = level
    end
end

--- Get the current log level
-- @return string
function logger.get_level()
    return current_level
end

--- Check if a message at the given level would be logged
-- @param level string
-- @return boolean
function logger.should_log(level)
    return (LEVEL_PRIORITY[level] or 999) >= (LEVEL_PRIORITY[current_level] or 0)
end

--- Log a verbose message (only shown at verbose level)
-- @param msg string
function logger.verbose(msg)
    if logger.should_log("verbose") then
        koreader_logger.dbg(PREFIX .. tostring(msg))
    end
end

--- Log an info message
-- @param msg string
function logger.info(msg)
    if logger.should_log("info") then
        koreader_logger.info(PREFIX .. tostring(msg))
    end
end

--- Log a warning message
-- @param msg string
function logger.warn(msg)
    if logger.should_log("warn") then
        koreader_logger.warn(PREFIX .. tostring(msg))
    end
end

return logger
