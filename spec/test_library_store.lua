-- Library store tests
-- Tests library_store.lua public API: init, fetchAll, getItems, getSortModes,
-- getCurrentSort, setSort, isLoaded
--
-- Run with: luajit spec/test_library_store.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

-- Stub KOReader dependencies
package.loaded["logger"] = {
    dbg = function() end,
    info = function() end,
    warn = function() end,
}

package.loaded["abs_logger"] = {
    verbose = function() end,
    info = function() end,
    warn = function() end,
    set_level = function() end,
}

local mock = require("spec/test_helper")

-- Mock api module — mock_api_data is set per test
local mock_api_data = {}
local mock_api_error = nil

package.loaded["api"] = {
    is_configured = function() return true end,
    getLibraryItems = function(lib_id, opts)
        if mock_api_error then
            return false, mock_api_error
        end
        return true, mock_api_data
    end,
}

local library_store = require("absaudio/library_store")

local passed = 0
local failed = 0
local errors = {}

-- Sample items for testing (reused across tests)
local SAMPLE_ITEMS = {
    {
        id = "li_aaa",
        mediaType = "book",
        addedAt = 1000,
        media = {
            duration = 3600,
            metadata = {
                title = "Alpha Book",
                authorName = "Zoe Author",
            },
        },
        userMediaProgress = nil,
    },
    {
        id = "li_bbb",
        mediaType = "book",
        addedAt = 3000,
        media = {
            duration = 7200,
            metadata = {
                title = "Beta Book",
                authorName = "Amy Writer",
            },
        },
        userMediaProgress = {
            currentTime = 500,
            isFinished = false,
            lastUpdate = 5000,
        },
    },
    {
        id = "li_ccc",
        mediaType = "book",
        addedAt = 2000,
        media = {
            duration = 5400,
            metadata = {
                title = "Charlie's Challenge",
                authorName = "Chuck Novelist",
            },
        },
        userMediaProgress = {
            currentTime = 200,
            isFinished = false,
            lastUpdate = 8000,
        },
    },
    {
        id = "li_ddd",
        mediaType = "book",
        addedAt = 4000,
        media = {
            duration = 1800,
            metadata = {
                title = "Delta Dawn",
                authorName = "Amy Writer",
            },
        },
        userMediaProgress = nil,
    },
    {
        id = "li_eee",
        mediaType = "book",
        addedAt = 5000,
        media = {
            duration = 9000,
            metadata = {
                title = "Echo Chamber",
                authorName = "Eva Storyteller",
            },
        },
        userMediaProgress = {
            currentTime = 9000,
            isFinished = true,
            lastUpdate = 6000,
        },
    },
}

local function run_test(name, fn)
    -- Reset state
    mock_api_data = {}
    mock_api_error = nil
    library_store.init()

    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("  ✓ " .. name)
    else
        failed = failed + 1
        table.insert(errors, { name = name, err = err })
        print("  ✗ " .. name)
        print("    " .. tostring(err))
    end
end

-- ============================================================
-- Test: init resets store state
-- ============================================================
run_test("init resets store state", function()
    -- After init, isLoaded should be false
    mock.assert_equals(library_store.isLoaded(), false, "isLoaded should be false after init")
end)

-- ============================================================
-- Test: isLoaded returns false before fetchAll
-- ============================================================
run_test("isLoaded returns false before fetchAll", function()
    mock.assert_equals(library_store.isLoaded(), false, "isLoaded should be false before fetch")
end)

-- ============================================================
-- Test: isLoaded returns true after successful fetchAll
-- ============================================================
run_test("isLoaded returns true after successful fetchAll", function()
    mock_api_data = { results = SAMPLE_ITEMS, total = #SAMPLE_ITEMS }

    local ok, err = library_store.fetchAll("lib_001")
    mock.assert_equals(ok, true, "fetchAll should succeed")
    mock.assert_equals(library_store.isLoaded(), true, "isLoaded should be true after fetch")
end)

-- ============================================================
-- Test: fetchAll returns error on API failure
-- ============================================================
run_test("fetchAll returns error on API failure", function()
    mock_api_error = { type = "network", message = "connection failed" }

    local ok, err = library_store.fetchAll("lib_001")
    mock.assert_equals(ok, false, "fetchAll should fail on API error")
    mock.assert_equals(library_store.isLoaded(), false, "isLoaded should remain false on error")
end)

-- ============================================================
-- Test: getItems returns paginated results with defaults
-- ============================================================
run_test("getItems returns paginated results with defaults", function()
    mock_api_data = { results = SAMPLE_ITEMS, total = #SAMPLE_ITEMS }
    library_store.fetchAll("lib_001")

    local result = library_store.getItems()
    mock.assert_equals(result.page, 1, "default page should be 1")
    mock.assert_equals(result.per_page, 25, "default per_page should be 25")
    mock.assert_equals(result.total_items, 5, "total_items should be 5")
    mock.assert_equals(result.total_pages, 1, "total_pages should be 1 for 5 items with per_page=25")
    mock.assert_equals(#result.items, 5, "should return all 5 items")
end)

-- ============================================================
-- Test: getItems pagination with per_page=2
-- ============================================================
run_test("getItems pagination with per_page=2", function()
    mock_api_data = { results = SAMPLE_ITEMS, total = #SAMPLE_ITEMS }
    library_store.fetchAll("lib_001")

    local result = library_store.getItems({ page = 1, per_page = 2 })
    mock.assert_equals(result.page, 1, "page should be 1")
    mock.assert_equals(result.per_page, 2, "per_page should be 2")
    mock.assert_equals(result.total_items, 5, "total_items should be 5")
    mock.assert_equals(result.total_pages, 3, "total_pages should be ceil(5/2)=3")
    mock.assert_equals(#result.items, 2, "page 1 should have 2 items")

    local result2 = library_store.getItems({ page = 2, per_page = 2 })
    mock.assert_equals(#result2.items, 2, "page 2 should have 2 items")

    local result3 = library_store.getItems({ page = 3, per_page = 2 })
    mock.assert_equals(#result3.items, 1, "page 3 should have 1 item")
end)

-- ============================================================
-- Test: getItems search filters by title (case-insensitive)
-- ============================================================
run_test("getItems search filters by title (case-insensitive)", function()
    mock_api_data = { results = SAMPLE_ITEMS, total = #SAMPLE_ITEMS }
    library_store.fetchAll("lib_001")

    local result = library_store.getItems({ search = "alpha" })
    mock.assert_equals(result.total_items, 1, "search 'alpha' should match 1 item")
    mock.assert_equals(library_store.getItemTitle(result.items[1]), "Alpha Book", "should match Alpha Book")
end)

-- ============================================================
-- Test: getItems search filters by author (case-insensitive)
-- ============================================================
run_test("getItems search filters by author (case-insensitive)", function()
    mock_api_data = { results = SAMPLE_ITEMS, total = #SAMPLE_ITEMS }
    library_store.fetchAll("lib_001")

    local result = library_store.getItems({ search = "amy" })
    mock.assert_equals(result.total_items, 2, "search 'amy' should match 2 items by Amy Writer")
end)

-- ============================================================
-- Test: getItems search returns empty when no match
-- ============================================================
run_test("getItems search returns empty when no match", function()
    mock_api_data = { results = SAMPLE_ITEMS, total = #SAMPLE_ITEMS }
    library_store.fetchAll("lib_001")

    local result = library_store.getItems({ search = "nonexistent" })
    mock.assert_equals(result.total_items, 0, "search 'nonexistent' should match 0 items")
    mock.assert_equals(#result.items, 0, "should return empty items array")
end)

-- ============================================================
-- Test: getItems sort by title_asc (default)
-- ============================================================
run_test("getItems sort by title_asc (default)", function()
    mock_api_data = { results = SAMPLE_ITEMS, total = #SAMPLE_ITEMS }
    library_store.fetchAll("lib_001")

    local result = library_store.getItems({ sort = "title_asc" })
    mock.assert_equals(library_store.getItemTitle(result.items[1]), "Alpha Book", "first should be Alpha Book")
    mock.assert_equals(library_store.getItemTitle(result.items[2]), "Beta Book", "second should be Beta Book")
    mock.assert_equals(library_store.getItemTitle(result.items[3]), "Charlie's Challenge", "third should be Charlie's Challenge")
    mock.assert_equals(library_store.getItemTitle(result.items[4]), "Delta Dawn", "fourth should be Delta Dawn")
    mock.assert_equals(library_store.getItemTitle(result.items[5]), "Echo Chamber", "fifth should be Echo Chamber")
end)

-- ============================================================
-- Test: getItems sort by title_desc
-- ============================================================
run_test("getItems sort by title_desc", function()
    mock_api_data = { results = SAMPLE_ITEMS, total = #SAMPLE_ITEMS }
    library_store.fetchAll("lib_001")

    local result = library_store.getItems({ sort = "title_desc" })
    mock.assert_equals(library_store.getItemTitle(result.items[1]), "Echo Chamber", "first should be Echo Chamber")
    mock.assert_equals(library_store.getItemTitle(result.items[5]), "Alpha Book", "last should be Alpha Book")
end)

-- ============================================================
-- Test: getItems sort by author_asc
-- ============================================================
run_test("getItems sort by author_asc", function()
    mock_api_data = { results = SAMPLE_ITEMS, total = #SAMPLE_ITEMS }
    library_store.fetchAll("lib_001")

    local result = library_store.getItems({ sort = "author_asc" })
    mock.assert_equals(library_store.getItemAuthor(result.items[1]), "Amy Writer", "first should be Amy Writer")
    mock.assert_equals(library_store.getItemAuthor(result.items[2]), "Amy Writer", "second should also be Amy Writer")
    mock.assert_equals(library_store.getItemAuthor(result.items[5]), "Zoe Author", "last should be Zoe Author")
end)

-- ============================================================
-- Test: getItems sort by author_desc
-- ============================================================
run_test("getItems sort by author_desc", function()
    mock_api_data = { results = SAMPLE_ITEMS, total = #SAMPLE_ITEMS }
    library_store.fetchAll("lib_001")

    local result = library_store.getItems({ sort = "author_desc" })
    mock.assert_equals(library_store.getItemAuthor(result.items[1]), "Zoe Author", "first should be Zoe Author")
    mock.assert_equals(library_store.getItemAuthor(result.items[5]), "Amy Writer", "last should be Amy Writer")
end)

-- ============================================================
-- Test: getItems sort by recently_added
-- ============================================================
run_test("getItems sort by recently_added", function()
    mock_api_data = { results = SAMPLE_ITEMS, total = #SAMPLE_ITEMS }
    library_store.fetchAll("lib_001")

    local result = library_store.getItems({ sort = "recently_added" })
    mock.assert_equals(result.items[1].id, "li_eee", "first should be Echo Chamber (addedAt=5000)")
    mock.assert_equals(result.items[2].id, "li_ddd", "second should be Delta Dawn (addedAt=4000)")
    mock.assert_equals(result.items[5].id, "li_aaa", "last should be Alpha Book (addedAt=1000)")
end)

-- ============================================================
-- Test: getItems sort by recently_played
-- ============================================================
run_test("getItems sort by recently_played", function()
    mock_api_data = { results = SAMPLE_ITEMS, total = #SAMPLE_ITEMS }
    library_store.fetchAll("lib_001")

    local result = library_store.getItems({ sort = "recently_played" })
    -- Charlie (lastUpdate=8000) > Echo (lastUpdate=6000) > Beta (lastUpdate=5000) > Alpha (nil) > Delta (nil)
    mock.assert_equals(result.items[1].id, "li_ccc", "first should be Charlie (lastUpdate=8000)")
    mock.assert_equals(result.items[2].id, "li_eee", "second should be Echo (lastUpdate=6000)")
    mock.assert_equals(result.items[3].id, "li_bbb", "third should be Beta (lastUpdate=5000)")
end)

-- ============================================================
-- Test: getItems pagination works with search filter
-- ============================================================
run_test("getItems pagination works with search filter", function()
    -- Create 30 items with "Series" in title
    local many_items = {}
    for i = 1, 30 do
        table.insert(many_items, {
            id = "li_series_" .. i,
            title = "Series Book " .. string.format("%02d", i),
            author = "Author " .. i,
            mediaType = "book",
            addedAt = i * 100,
            media = { duration = 3600 },
            userMediaProgress = nil,
        })
    end
    -- Add an unrelated item
    table.insert(many_items, {
        id = "li_other",
        title = "Unrelated",
        author = "Nobody",
        mediaType = "book",
        addedAt = 99,
        media = { duration = 3600 },
        userMediaProgress = nil,
    })

    mock_api_data = { results = many_items, total = #many_items }
    library_store.fetchAll("lib_001")

    local result = library_store.getItems({ search = "series", per_page = 10 })
    mock.assert_equals(result.total_items, 30, "should find 30 'Series' items")
    mock.assert_equals(result.total_pages, 3, "should have 3 pages")
    mock.assert_equals(#result.items, 10, "page 1 should have 10 items")
end)

-- ============================================================
-- Test: getSortModes returns all 6 sort modes in order
-- ============================================================
run_test("getSortModes returns all 6 sort modes in order", function()
    local modes = library_store.getSortModes()
    mock.assert_equals(#modes, 6, "should have 6 sort modes")
    mock.assert_equals(modes[1], "title_asc", "first should be title_asc")
    mock.assert_equals(modes[2], "title_desc", "second should be title_desc")
    mock.assert_equals(modes[3], "author_asc", "third should be author_asc")
    mock.assert_equals(modes[4], "author_desc", "fourth should be author_desc")
    mock.assert_equals(modes[5], "recently_added", "fifth should be recently_added")
    mock.assert_equals(modes[6], "recently_played", "sixth should be recently_played")
end)

-- ============================================================
-- Test: getCurrentSort returns default after init
-- ============================================================
run_test("getCurrentSort returns default after init", function()
    mock.assert_equals(library_store.getCurrentSort(), "title_asc", "default sort should be title_asc")
end)

-- ============================================================
-- Test: setSort changes the current sort mode
-- ============================================================
run_test("setSort changes the current sort mode", function()
    library_store.setSort("author_desc")
    mock.assert_equals(library_store.getCurrentSort(), "author_desc", "sort should be author_desc after setSort")
end)

-- ============================================================
-- Test: getItems uses stored sort when no sort in opts
-- ============================================================
run_test("getItems uses stored sort when no sort in opts", function()
    mock_api_data = { results = SAMPLE_ITEMS, total = #SAMPLE_ITEMS }
    library_store.fetchAll("lib_001")

    library_store.setSort("title_desc")
    local result = library_store.getItems()
    mock.assert_equals(library_store.getItemTitle(result.items[1]), "Echo Chamber", "should use stored sort (title_desc)")
end)

-- ============================================================
-- Test: wasLastFetchSuccessful returns nil before any fetch
-- ============================================================
run_test("wasLastFetchSuccessful returns nil before any fetch", function()
    mock.assert_equals(library_store.wasLastFetchSuccessful(), nil, "should be nil before any fetch")
end)

-- ============================================================
-- Test: wasLastFetchSuccessful returns true after successful fetch
-- ============================================================
run_test("wasLastFetchSuccessful returns true after successful fetch", function()
    mock_api_data = { results = SAMPLE_ITEMS, total = #SAMPLE_ITEMS }
    library_store.fetchAll("lib_001")
    mock.assert_equals(library_store.wasLastFetchSuccessful(), true, "should be true after successful fetch")
end)

-- ============================================================
-- Test: wasLastFetchSuccessful returns false after failed fetch
-- ============================================================
run_test("wasLastFetchSuccessful returns false after failed fetch", function()
    mock_api_error = { type = "network", message = "connection failed" }
    library_store.fetchAll("lib_001")
    mock.assert_equals(library_store.wasLastFetchSuccessful(), false, "should be false after failed fetch")
end)

-- ============================================================
-- Test: wasLastFetchSuccessful resets to nil on init
-- ============================================================
run_test("wasLastFetchSuccessful resets to nil on init", function()
    mock_api_data = { results = SAMPLE_ITEMS, total = #SAMPLE_ITEMS }
    library_store.fetchAll("lib_001")
    mock.assert_equals(library_store.wasLastFetchSuccessful(), true, "should be true after fetch")
    library_store.init()
    mock.assert_equals(library_store.wasLastFetchSuccessful(), nil, "should be nil after init")
end)

-- ============================================================
-- Test: wasLastFetchSuccessful tracks across multiple fetches
-- ============================================================
run_test("wasLastFetchSuccessful tracks across multiple fetches", function()
    -- First: success
    mock_api_data = { results = SAMPLE_ITEMS, total = #SAMPLE_ITEMS }
    library_store.fetchAll("lib_001")
    mock.assert_equals(library_store.wasLastFetchSuccessful(), true, "first fetch: should be true")

    -- Second: failure
    mock_api_error = { type = "network", message = "connection failed" }
    library_store.fetchAll("lib_001")
    mock.assert_equals(library_store.wasLastFetchSuccessful(), false, "second fetch: should be false")

    -- Third: success again
    mock_api_error = nil
    library_store.fetchAll("lib_001")
    mock.assert_equals(library_store.wasLastFetchSuccessful(), true, "third fetch: should be true")
end)

-- ============================================================
-- Summary
-- ============================================================
print(string.format("\n%d passed, %d failed", passed, failed))

if #errors > 0 then
    print("\nFailures:")
    for _, e in ipairs(errors) do
        print("  " .. e.name .. ": " .. tostring(e.err))
    end
    os.exit(1)
end
