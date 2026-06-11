-- Library store for absaudio.koplugin
-- Manages fetching all items from ABS and providing client-side
-- search, sort, and pagination against the cached result set.
--
-- Public API:
--   library_store.init()                    -- reset store state
--   library_store.fetchAll(library_id)      -- fetch all items from ABS, cache internally
--   library_store.getItems(opts)            -- get paginated/filtered/sorted items
--   library_store.getSortModes()            -- ordered list of sort mode keys
--   library_store.getCurrentSort()          -- current sort key
--   library_store.setSort(key)              -- set sort mode
--   library_store.isLoaded()               -- true when items have been fetched
-- Return convention: structured table for getItems (paginated result);
--   (boolean, count) for fetchAll; direct value for accessors.

local abs_logger = require("abs_logger")
local has_api, api = pcall(require, "api")

local library_store = {}

-- Sort modes in display/cycle order
local SORT_MODES = {
    "title_asc",
    "title_desc",
    "author_asc",
    "author_desc",
    "recently_added",
    "recently_played",
}

------------------------------------------------------------------------
-- Helpers: extract title/author from ABS API response shape
-- ABS returns: item.media.metadata.title, item.media.metadata.authorName
-- Fallback: item.title, item.author (for test compat / edge cases)
------------------------------------------------------------------------
local function _get_item_title(item)
    if item.media and item.media.metadata and item.media.metadata.title then
        return item.media.metadata.title
    end
    return item.title or ""
end

local function _get_item_author(item)
    if item.media and item.media.metadata and item.media.metadata.authorName then
        return item.media.metadata.authorName
    end
    return item.author or ""
end

local DEFAULT_PER_PAGE = 25
local DEFAULT_SORT = "title_asc"

-- Internal state
local all_items = {}
local current_sort = DEFAULT_SORT
local last_fetch_ok = nil  -- nil=never tried, true=success, false=failure

--- Reset store state (clear cached items and sort)
function library_store.init()
    all_items = {}
    current_sort = DEFAULT_SORT
    last_fetch_ok = nil
    abs_logger.verbose("Library store initialized (state reset)")
end

--- Fetch all items from an ABS library and cache them
-- @param library_id string  ABS library ID
-- @return boolean ok
-- @return string|error  "ok" or error info
function library_store.fetchAll(library_id)
    if not has_api then
        return false, { type = "network", message = "API module not available" }
    end

    abs_logger.info("Fetching all items from library " .. library_id)

    -- Fetch all items (limit=0 means all per ABS API)
    local ok, data = api.getLibraryItems(library_id, { limit = 0 })
    if not ok then
        abs_logger.warn("Failed to fetch library items: " .. tostring(data and data.message or "unknown"))
        last_fetch_ok = false
        return false, data
    end

    all_items = data.results or {}
    last_fetch_ok = true
    abs_logger.info("Cached " .. #all_items .. " items from library " .. library_id)
    return true
end

--- Check if items have been loaded
-- @return boolean
function library_store.isLoaded()
    return #all_items > 0
end

--- Check if the last fetchAll call was successful
--- @return boolean|nil  nil=never tried, true=success, false=failure
function library_store.wasLastFetchSuccessful()
    return last_fetch_ok
end

--- Get the ordered list of sort mode keys
-- @return table  array of sort mode strings
function library_store.getSortModes()
    return SORT_MODES
end

--- Get the current sort mode
-- @return string  current sort key
function library_store.getCurrentSort()
    return current_sort
end

--- Set the current sort mode
-- @param key string  one of the SORT_MODES values
function library_store.setSort(key)
    current_sort = key
    abs_logger.verbose("Sort mode set to: " .. key)
end

--- Filter items by search query (matches title or author, case-insensitive)
-- @param items table  array of items to filter
-- @param query string  search text
-- @return table  filtered array
local function filter_items(items, query)
    if not query or query == "" then
        return items
    end
    local lower_query = query:lower()
    local filtered = {}
    for _, item in ipairs(items) do
        local title = _get_item_title(item):lower()
        local author = _get_item_author(item):lower()
        if title:find(lower_query, 1, true) or author:find(lower_query, 1, true) then
            table.insert(filtered, item)
        end
    end
    return filtered
end

--- Sort items by the given sort mode
-- @param items table  array of items to sort (sorted in place)
-- @param sort_key string  sort mode key
local function sort_items(items, sort_key)
    if sort_key == "title_asc" then
        table.sort(items, function(a, b)
            return _get_item_title(a):lower() < _get_item_title(b):lower()
        end)
    elseif sort_key == "title_desc" then
        table.sort(items, function(a, b)
            return _get_item_title(a):lower() > _get_item_title(b):lower()
        end)
    elseif sort_key == "author_asc" then
        table.sort(items, function(a, b)
            return _get_item_author(a):lower() < _get_item_author(b):lower()
        end)
    elseif sort_key == "author_desc" then
        table.sort(items, function(a, b)
            return _get_item_author(a):lower() > _get_item_author(b):lower()
        end)
    elseif sort_key == "recently_added" then
        table.sort(items, function(a, b)
            return (a.addedAt or 0) > (b.addedAt or 0)
        end)
    elseif sort_key == "recently_played" then
        table.sort(items, function(a, b)
            local a_time = a.userMediaProgress and a.userMediaProgress.lastUpdate or 0
            local b_time = b.userMediaProgress and b.userMediaProgress.lastUpdate or 0
            return a_time > b_time
        end)
    end
end

--- Get a paginated, filtered, sorted slice of items
-- @param opts table|nil  { page, per_page, search, sort }
-- @return table  { items, page, per_page, total_pages, total_items }
function library_store.getItems(opts)
    opts = opts or {}
    local page = opts.page or 1
    local per_page = opts.per_page or DEFAULT_PER_PAGE
    local search = opts.search
    local sort_key = opts.sort or current_sort

    -- Work on a copy so sort/filter don't mutate the cache
    local items = {}
    for _, item in ipairs(all_items) do
        table.insert(items, item)
    end

    -- Filter
    items = filter_items(items, search)

    -- Sort
    sort_items(items, sort_key)

    -- Paginate
    local total_items = #items
    local total_pages = math.ceil(total_items / per_page)
    if total_pages == 0 then total_pages = 1 end

    local start_idx = (page - 1) * per_page + 1
    local end_idx = math.min(start_idx + per_page - 1, total_items)

    local page_items = {}
    for i = start_idx, end_idx do
        table.insert(page_items, items[i])
    end

    return {
        items = page_items,
        page = page,
        per_page = per_page,
        total_pages = total_pages,
        total_items = total_items,
    }
end

--- Get item title from nested metadata (handles both API and flat shapes)
-- @param item table  ABS library item
-- @return string
function library_store.getItemTitle(item)
    return _get_item_title(item)
end

--- Get item author from nested metadata (handles both API and flat shapes)
-- @param item table  ABS library item
-- @return string
function library_store.getItemAuthor(item)
    return _get_item_author(item)
end

return library_store
