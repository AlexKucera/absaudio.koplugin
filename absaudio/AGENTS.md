# absaudio/ — UI Widgets, Navigation, Download Pipeline, Data Stores

## Purpose

Core plugin package containing all runtime modules for the absaudio KOReader plugin. Houses KOReader UI widgets (dashboard, library browser, book detail, download progress), the navigator (screen stack), data stores (library_store, cover_cache), the download pipeline (downloader, chunked_http), and shared widget helpers.

## Ownership

Each module is a self-contained Lua file with a clear public API documented in the file header. Modules import from root-level infrastructure (api, config, manifest, error_handler, abs_logger) and from each other minimally.

## Local Contracts

### Widget modules (dashboard_widget, library_browser, book_detail, download_progress)
- Follow the `prepare()` / `show()` split pattern: `prepare()` fetches data and returns `(data, nil)` or `(nil, error_info)`, `show()` renders from pre-fetched data
- Use `InputContainer` as the base widget class
- Set `covers_fullscreen = true` on fullscreen overlays
- Set `show_parent = self` on `ScrollableContainer` children
- Use `UIManager:setDirty(widget, "full")` after widget swaps — default `"fast"` mode leaves stale content
- Use `UIManager:scheduleIn(0.1, ...)` to defer widget shows after menu close — TouchMenu callbacks are synchronous
- Show new widget **before** closing old one, then schedule the close — closing first destroys context
- Never register `ges_events.Swipe` on widgets with `ScrollableContainer` children

### Navigator (`navigator.lua`)
- Manages screen stack via `register`, `push`, `pop`, `reset`
- Replaces callback chains with a declarative navigation pattern
- Single global instance used by main.lua and all widgets

### Download pipeline (`downloader.lua`, `chunked_http.lua`)
- `downloader.lua`: orchestrates filename sanitization, format filtering, file selection, and download sequencing
- `chunked_http.lua`: raw socket I/O bypassing `socket.http` to allow `coroutine.yield()` between chunks (socket.http wraps in C-call boundary)
- Chunk reads use `scheduleIn(0.05, ...)` between reads — `scheduleIn(0)` starves UIManager event loop
- Socket timeout set to 10s to avoid freezing UI on stalled servers
- Resume support: byte-level via HTTP `Range` header, file-level via manifest status tracking

### Data stores (`library_store.lua`, `cover_cache.lua`)
- `library_store`: fetches all items from ABS in one call, provides client-side search/sort/pagination
- `cover_cache`: fetches and caches cover JPEGs locally alongside downloads

### Widget helpers (`widget_helpers.lua`)
- Shared utilities: `format_duration`, `format_time`, `format_file_size`, `addSeparator`, `makeTappableButton`
- Extracted from triplicated code across dashboard, library_browser, book_detail

## Work Guidance

- KOReader font names: `cfont`, `tfont`, `smalltfont`, `x_smalltfont`, `largeffont`, `scfont` — use with explicit size: `Font:getFace("tfont", 26)`
- DPI-scale images (`Screen:scaleBySize()`) but use fixed sizes for text — DPI-scaled text is enormous on 300 DPI devices
- Emojis don't render in `TextWidget` — use `IconWidget` with built-in icon names (e.g., `appbar.search`)
- Use `ltn12.sink.table()` + bulk `file:write()` for binary responses — streaming `file_sink` truncates at TLS chunk boundaries
- `UIManager:scheduleIn` silently swallows Lua errors — use synchronous `pcall` for critical logic
- Lua closure scoping: `local x; x = Table:new{...}` pattern when closure references the table being defined

## Verification

- Run full test suite from project root: `busted spec/`
- Each module has a corresponding `spec/test_<module>.lua`
- All tests must pass before committing

## Child DOX Index

No child directories — all modules are flat Lua files in this package.
