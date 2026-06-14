# spec/ — Test Suite

## Purpose

Busted-based test suite for the absaudio plugin. Each source module has a corresponding `test_<module>.lua` file. Tests run outside KOReader using a lightweight mock framework defined in `test_helper.lua`.

## Ownership

Tests mirror the source layout:
- Root modules: `test_api.lua`, `test_config.lua`, `test_manifest.lua`, `test_error_handler.lua`, `test_logger.lua`, `test_main.lua`
- absaudio/ modules: `test_navigator.lua`, `test_downloader.lua`, `test_chunked_http.lua`, `test_cover_cache.lua`, `test_library_store.lua`, `test_library_browser.lua`, `test_book_detail.lua`, `test_dashboard_widget.lua`, `test_widget_helpers.lua`, `test_chapter_navigator.lua`

## Local Contracts

### Mock framework (`test_helper.lua`)
- `mock.create_lua_settings(initial_data)` — mock `LuaSettings` backed by a plain Lua table (no file I/O)
- `mock.create_mock_logger()` — mock logger with recorded messages
- `mock.create_mock_uimanager()` — mock UIManager that records scheduled functions
- Stubs for KOReader globals that don't exist outside the device runtime

### Test conventions
- Each test file `require`s the module under test and the mock helper
- Modules are reset between tests using module-level `_reset()` functions where available
- Use `finally()` to restore global state modified during tests
- Network tests mock `socket.http` responses — no real HTTP calls

## Work Guidance

- Add a test file when adding a new source module
- Follow the naming convention: `test_<module_name>.lua`
- Use `describe`/`it` blocks matching the public API being tested
- Group by function name when a module has many exported functions

## Verification

- Run from project root: `busted spec/`
- Current count: ~280+ tests across all files
- All tests must pass before any commit

## Child DOX Index

No child directories — all test files are flat in this directory.
