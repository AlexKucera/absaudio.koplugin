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

### Pure logic modules

All zero-dependency (no FFI, no KOReader globals, no I/O) — the deepest, most testable modules. Tested with the custom `run_test`/`mock.assert_equals` harness via `luajit` (NOT busted — busted is not installed).

#### `chapter_navigator.lua` — position ↔ chapter mapping
- Maps a global playback position (seconds) to ABS chapters (`{ id, start, end, title }` on `media.chapters`, a single global timeline)
- Public API: `current(pos, chapters)`, `next(pos, chapters)`, `previous(pos, chapters, opts)`, `chapter_start(index, chapters)`
- Boundary convention: half-open `[start, end)` — a position at a boundary belongs to the LATER chapter; beyond-last clamps to last; empty → `(0, nil)`
- `previous()` uses smart-restart UX (deep in chapter >`opts.threshold` seconds, default 10 → restart current; near start → previous chapter, clamped to first)
- Used by `book_detail.lua` for: chapter-name display, tappable chapter list (seek-to-chapter), next/prev skip buttons

#### `time_math.lua` — FFmpeg time-base rescale arithmetic
- Pure `av_rescale_q` arithmetic (issue #32, audio slice A): converts a packet PTS in a stream's `time_base` rational `{num, den}` to ms/seconds, with half-away-from-zero rounding (FFmpeg `AV_ROUND_NEAR_INF`)
- Public API: `rescale(value, from_tb, to_tb)`, `to_ms(pts, time_base)`, `to_seconds(pts, time_base)`, `ms_to_seconds(ms)`, `seconds_to_ms(sec)`, `clamp(value, max)`
- Foundation for the FFmpeg backend's live-position computation (PRD #31); no caller yet

#### `ring_buffer.lua` — PCM ring-buffer index math
- Pure index arithmetic for the FFmpeg backend's decoupled decode/output ring buffer (PRD #31). No PCM storage — just cursor math
- State: immutable `{capacity, write, read}` where `write`/`read` are absolute monotonic byte counters (only grow); `fill = write - read`; wraparound via `counter % capacity`
- Public API: `new(capacity)`, `fill`, `free`, `empty`, `full`, `can_write(n)` (overrun check), `can_read(n)` (underrun check), `write(n)`/`read(n)` (return NEW state, error on overrun/underrun), `write_slot`/`read_slot`

#### `atempo.lua` — FFmpeg atempo filter-chain builder
- Builds valid `atempo` filter-chain strings for arbitrary playback speeds (issue #32, audio slice A). Single stage covers `[0.5, 2.0]`; out-of-range chains 2.0/0.5 stages (product of all stages == input speed)
- Public API: `chain(speed)` → string (e.g. `"atempo=1.5"`, `"atempo=2,atempo=2"`); `STAGE_MIN = 0.5`, `STAGE_MAX = 2.0` constants. Errors if speed ≤ 0 or non-number. `%g` formatting mirrors `player.format_speed`

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
