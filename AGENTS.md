<!-- Lua Best Practices:start  -->

## Lua Best Practices

	1. Use `local` everywhere by default.
	2. Return values explicitly and early.
	3. Keep tables shallow and consistent in shape.
	4. Use modules as namespaces, not as heavyweight objects.
	5. Avoid hidden state unless the module is truly stateful.
	6. Prefer plain functions over complex inheritance patterns.
	7. Validate inputs at boundaries, not deep inside the code.
	8. Add tests for edge cases where `nil` or missing keys can happen.

<!-- Lua Best Practices:end -->

## Project Learnings

<!-- distill-learnings: project-learnings -->

### KOReader Widgets
- Set `covers_fullscreen = true` on fullscreen overlays, and `show_parent = self` on ScrollableContainer — without these, repaints are silently discarded (source: `docs/devlog/20260608-dashboard-widget-fullscreen-rendering-fixes_log.md`, `docs/devlog/20260608-issue04-library-browser-scrolling-pagination-fix_log.md`)
- Use `UIManager:scheduleIn(0.1, ...)` to defer widget shows after menu close — TouchMenu calls callbacks synchronously before `closeMenu()` (source: `docs/devlog/20260608-dashboard-widget-fullscreen-rendering-fixes_log.md`)
- Show the new widget **before** closing the old one, then schedule the close — closing first destroys context (source: `docs/devlog/20260608-issue04-library-browser-book-detail-view_log.md`)
- `UIManager:scheduleIn` silently swallows Lua errors — use synchronous `pcall` for critical logic (source: `docs/devlog/20260608-issue04-library-browser-book-detail-view_log.md`)
- **Never use `scheduleIn(0, fn)` for pump loops** — `UIManager:handleInput()` drains ALL due tasks in a `repeat…until` loop before processing input events. `scheduleIn(0)` makes tasks "due now" (`time.now() + 0`), so each pump reschedules itself as immediately due, starving the event loop of input. Cancel taps, gestures, and key events are queued but never dispatched. Use `scheduleIn(0.05, fn)` (50ms) instead — the drain loop exits, input is processed, and ~20 pumps/sec is plenty for progress UI. (source: cancel-download-hang fix)
- Use `UIManager:setDirty(widget, "full")` after widget swaps — e-ink default `"fast"` mode leaves stale framebuffer content (source: `docs/devlog/20260609-issue04-library-browser-search-partial-repaint-fix_log.md`)
- **Use `setDirty(widget, "partial")` for high-frequency periodic repaints** (e.g. playback progress ticks); reserve `"full"` for widget swaps/transitions. `"full"` = a full black-then-white e-ink refresh = ugly flashing when called every 0.5s. `"partial"` repaints without the flash, matching the native audiobook player. (source: `docs/devlog/20260614-fix-playback-ui-full-screen-flash_log.md`)
- **Never silently default `download_dir` to `/tmp`** — on PocketBook `/tmp` is not exposed via USB mass storage and may be tmpfs (gone after reboot), so downloads vanish from the user's view. Use `config.get_download_dir()`: prefers the PocketBook native-player dir (`/mnt/ext1/Audio Books`, scanned by the stock audiobook player → free fallback playback) when it exists, else `<koreader_data>/absaudio_books`. Never `/tmp`. (source: `docs/devlog/20260614-fix-download-dir-tmp-fallback_log.md`)
- **TextWidget caches its rendered bitmap** — changing `.text` alone won't update the display. Call `:free()` after setting new text to invalidate the cache before `setDirty`. (source: `docs/devlog/20260614-fix-playback-ui-not-updating_log.md`)
- Registering `ges_events.Swipe` intercepts ALL swipes — don't register it on widgets with ScrollableContainer children (source: `docs/devlog/20260608-issue04-library-browser-scrolling-pagination-fix_log.md`)

### KOReader UI
- Valid font names: `cfont`, `tfont`, `smalltfont`, `x_smalltfont`, `largeffont`, `scfont` — use with explicit size: `Font:getFace("tfont", 26)` (source: `docs/devlog/20260608-dashboard-widget-fullscreen-rendering-fixes_log.md`)
- DPI-scale images (`Screen:scaleBySize()`) but use fixed sizes for text — DPI-scaled text is enormous on 300 DPI devices (source: `docs/devlog/20260608-issue04-cover-sizing-dynamic-pagination-persistent-caching_log.md`)
- Emojis don't render in TextWidget — use `IconWidget` with built-in icon names (e.g., `appbar.search`) (source: `docs/devlog/20260609-issue04-library-browser-search-feature_log.md`)
- **`ui/time.now()` returns an fts-encoded number, not a table** — do NOT index `.sec`/`.usec`. Use `time.to_number(time.now())` for float seconds (4 decimal precision) or `time.to_s()` for integer seconds. (source: `docs/devlog/20260614-fix-playback-ui-not-updating_log.md`)
- **Socket reads block the coroutine** — `sock:receive()` inside a coroutine is synchronous; it blocks until data arrives or timeout expires. For cancellable downloads, yield between chunks and use a small `scheduleIn` delay (not 0) so the UI event loop can process cancel taps between reads. Set socket timeout low (e.g. 10s) so a stalled server doesn't freeze the UI for 30s per chunk. (source: cancel-download-hang fix)
- **`LuaSettings:saveSetting()` is in-memory only — nothing hits disk until `:flush()`.** And `LuaSettings:open()` re-reads from disk via `dofile()` on every call, so re-running a singleton `init()` that calls `:open()` discards all unflushed mutations (a successful download's state simply vanished). Make singleton `init()` idempotent (early-return once `settings` is set) and call `:flush()` after every mutation, or a crash loses all state. (source: `docs/devlog/20260610-fix-manifest-init-discard-download-state_log.md`)
- **`ImageWidget` renders a nonexistent/invalid local path as a checkerboard pattern, not an error.** Always verify the file exists (`lfs.attributes(path, "mode") == "file"`) before constructing an `ImageWidget` from a local path, falling through to a placeholder/`cover_cache` when absent. (source: `docs/devlog/20260610-fix-manifest-init-discard-download-state_log.md`)
- **`Device.input.group.<Name>` is always a TABLE of key-name strings** (e.g. `Back = { "Back" }`, `Cursor = { "Up", "Down", ... }`; `Back` gains `"Backspace"` when the `backspace_as_back` setting is on). KOReader uses `table.insert(group.Back, ...)` and `ipairs(group.Back)`. **Never mock it as a bare string** (`group = { Back = "Back" }` → `ipairs`-on-string crash in `DashboardView:init`); use `group = { Back = { "Back" } }`. (source: KOReader `frontend/device/input.lua`; fixed across all spec mocks 2026-06-14)

### Lua Gotchas
- **Closure scoping:** `local x = { cb = function() x:method() end }` — `x` isn't declared yet when closure is created. Fix: `local x; x = Table:new{...}` (source: `docs/devlog/20260609-issue04-library-browser-search-feature_log.md`)
- **KOReader globals:** some modules (e.g., `lfs`) exist as `_G.lfs`, not loadable packages. Pattern: `pcall(require, "lfs")` then fall back to `_G.lfs` (source: `docs/devlog/20260608-issue04-library-browser-fixes-titles-covers-caching_log.md`)
- **Colon-call closures:** `obj.paintTo = function(bb, x, y)` (missing `self`) causes a parameter shift when called via `obj:paintTo(bb, x, y)` — Lua expands to `obj.paintTo(obj, bb, x, y)`, so `bb` receives the widget, `x` receives the BlitBuffer. This mimics a broken BlitBuffer. Always include `self`: `function(self, bb, x, y)` or use `function(self, ...)` passthrough. (source: `docs/devlog/20260614-fix-playback-ui-not-updating_log.md`)
- **Cannot `coroutine.yield()` across a C-call boundary (Lua 5.1/LuaJIT).** `socket.http.request()` wraps the whole call in `socket.protect(pcall)` — C functions baked into the `.so` binary — so any `coroutine.yield()` inside an ltn12 sink callback runs inside a C frame and throws `attempt to yield across C-call boundary`. To yield during downloads, bypass `socket.http.request` entirely with raw socket I/O (`sock:receive()` in a loop) and yield *between* receives, when the C frame has returned. (source: `docs/devlog/20260609-fix-yield-across-c-call-boundary-download_log.md`)
- **Calling a plain-function module table with `:` injects the table as the first argument.** Utility modules like `config`, `fs_helpers` export *plain functions, not methods* — `config:get(key)` passes the `config` table as `self`, shifting every parameter (e.g. `lfs.attributes(table)` → "string expected, got table"). Fails silently or with a confusing error. Use dot-call: `config.get(key)`, `fs.get_file_size(path)`. (sources: `docs/devlog/20260610-pr22-review-findings-self-contained-book-detail_log.md`, `docs/devlog/20260610-fix-ebook-audio-download-status-independent_log.md`)

### Networking
- Use `ltn12.sink.table()` + bulk `file:write()` for binary responses — streaming `file_sink` produces truncated files at TLS chunk boundaries (source: `docs/devlog/20260608-issue04-cover-image-truncation-fix_log.md`)

### ABS API Testing
- Credentials for direct API testing are in `login.txt` at the project root (server URL + API token). Use `curl -H "Authorization: Bearer $TOKEN" $URL/api/libraries` to verify connectivity or explore endpoints without going through the plugin.
- **Stub backend has dual time mode:** default is real-time (wall-clock via `ui/time`) for emulator use; calling `_advanceTime()` switches to manual virtual-clock mode for deterministic tests. Do NOT remove `_advanceTime()` — all player tests depend on it. (source: `docs/devlog/20260614-fix-playback-ui-not-updating_log.md`)

## Session Logs

Session logs are written to `docs/devlog/` after each completed task, issue fix, or milestone.
They capture what was done, decisions & rationale, gotchas & fixes, and next steps. Before starting a new session, read the previous session logs.
| 2026-06-14 | issue | [issue07-chapter-navigation-skip-controls-speed-control_log.md](docs/devlog/20260614-issue07-chapter-navigation-skip-controls-speed-control_log.md) | Issue #7/Slice 6: new `chapter_navigator.lua` pure module (current/next/previous/chapter_start, smart-restart prev); speed `next_speed`/`format_speed` in player; chapter name widget + ⏮/⏭/speed-badge row + seek-to-chapter in book_detail; persisted speed (config default 1×); 44 new tests (30 navigator, +4 player, +2 config, +8 book_detail) |
| 2026-06-14 | issue | [fix-playback-ui-not-updating_log.md](docs/devlog/20260614-fix-playback-ui-not-updating_log.md) | Fixed frozen playback UI: stub backend now uses real-time wall clock for emulator (was frozen virtual clock); added play/pause icon toggle; 4 new tests; 43 book_detail + 75 player pass |
| 2026-06-14 | generic | [fix-playback-ui-full-screen-flash_log.md](docs/devlog/20260614-fix-playback-ui-full-screen-flash_log.md) | Playback UI full-screen e-ink flash every 0.5s; changed `setDirty(target, "full")` → `"partial"` in `_updatePlaybackDisplay()`; reserve `"full"` for widget swaps; 51 book_detail / 366 total pass
| 2026-06-14 | generic | [fix-download-dir-tmp-fallback_log.md](docs/devlog/20260614-fix-download-dir-tmp-fallback_log.md) | Removed silent `/tmp/audiobooks` fallback in downloader; added `config.default_download_dir()`/`get_download_dir()` (persistent KOReader data dir); pre-fill Settings field; +4 config tests; 18 config + 82 downloader pass
| 2026-06-14 | generic | [fix-library-browser-infomessage-crash_log.md](docs/devlog/20260614-fix-library-browser-infomessage-crash_log.md) | library_browser.lua used InfoMessage (4 sites) without requiring it → crash in prepare() error path; added require; fixes 7 long-standing test_library_browser InfoMessage-nil failures; also fixed audio_probe IsPlayingMP3 undefined-symbol crash guard; 17 library_browser pass |
| 2026-06-14 | decision | [decision-audio-backend-path-c-ffmpeg_log.md](docs/devlog/20260614-decision-audio-backend-path-c-ffmpeg_log.md) | Path C chosen: build in-app audio on libaudio-engine.so FFmpeg+ALSA (Design 3, decoupled decode ring-buffer). 5 device probes killed inkview API (gutted) + path B (GetAudioPlayingInfo NULL for our process). All needed symbols confirmed present. 7-slice plan; handoff doc for multi-session build |
| 2026-06-14 | generic | [fix-playback-ui-full-screen-flash_log.md](docs/devlog/20260614-fix-playback-ui-full-screen-flash_log.md) | Playback UI full-screen e-ink flash every 0.5s; `setDirty(target,"full")`→`"partial"` in `_updatePlaybackDisplay()` |
| 2026-06-14 | generic | [fix-dashboard-widget-mock-ipairs-string-crash_log.md](docs/devlog/20260614-fix-dashboard-widget-mock-ipairs-string-crash_log.md) | Fixed 19 dashboard test errors (`ipairs`-on-string crash): `Device.input.group.Back` mock was a bare string but KOReader defines it as a table (`{ "Back" }`); corrected shape in 9 occurrences/8 spec files; production code unchanged; full suite now 577 green
| 2026-06-09 | issue | [issue17-dashboard-data-render-split_log.md](docs/devlog/20260609-issue17-dashboard-data-render-split_log.md) | Extracted `dashboard.prepare()` from `show()`; 4 new tests; 166 total pass |
| 2026-06-09 | issue | [issue18-book-detail-data-render-split_log.md](docs/devlog/20260609-issue18-book-detail-data-render-split_log.md) | Extracted `detail.prepare()` from `show()`; 4 new tests; 172 total pass |
| 2026-06-09 | issue | [issue20-main-lua-navigator-tests_log.md](docs/devlog/20260609-issue20-main-lua-navigator-tests_log.md) | Created `spec/test_main.lua` with 10 tests; navigator registration, onOpenDashboard wiring, dispatcher routing, first-run behavior; 196 total pass |
| 2026-06-10 | generic | [dashboard-downloaded-books-tappable-detail-nav_log.md](docs/devlog/20260610-dashboard-downloaded-books-tappable-detail-nav_log.md) | Made downloaded books in dashboard tappable; added `_onBookTap` → nav.push('detail'); 2 new tests; 311 total pass |

<!-- write-log: session-log-index -->
| 2026-06-14 | issue | [issue32-audio-slice-a-pure-audio-math-library_log.md](docs/devlog/20260614-issue32-audio-slice-a-pure-audio-math-library_log.md) | Pure FFmpeg math foundation (3 modules): `time_math.lua` (av_rescale_q, s↔ms, clamp), `ring_buffer.lua` (immutable PCM index math, 11 fns), `atempo.lua` (filter-chain builder w/ chaining); 53 new tests; 3 parallel TDD workers; slice A of PRD #31 audio backend
| 2026-06-11 | issue | [issue23-extract-shared-fs-helpers-module_log.md](docs/devlog/20260611-issue23-extract-shared-fs-helpers-module_log.md) | Created fs_helpers.lua with mkdir_p/get_file_size/delete_file/delete_dir; replaced inline mkdir in cover_cache+book_detail; 12 new tests; 341 total pass |
| 2026-06-11 | issue | [issue24-pcall-guard-abs-logger-require_log.md](docs/devlog/20260611-issue24-pcall-guard-abs-logger-require_log.md) | pcall-guarded require('logger') in abs_logger with print fallback; 3 new tests; 344 total pass |
| 2026-06-11 | issue | [issue26-remove-dead-download-delete-code-library-browser_log.md](docs/devlog/20260611-issue26-remove-dead-download-delete-code-library_browser_log.md) | Removed 406 lines dead download/delete code from library_browser; 4 new negative tests; 330 total pass |
| 2026-06-11 | issue | [issue28-unify-http-error-classification-api-error-handler_log.md](docs/devlog/20260611-issue28-unify-http-error-classification-api-error-handler_log.md) | Unified HTTP error classification: api delegates to error_handler.classify_http_status(); 6 agreement tests; 353 total pass |
| 2026-06-11 | issue | [issue25-trim-downloader-bloat-dead-code-misplaced-utilities_log.md](docs/devlog/20260611-issue25-trim-downloader-bloat-dead-code-misplaced-utilities_log.md) | Deleted 2 dead functions, moved format_bytes to widget_helpers, extracted _download_one_file helper; 763→660 lines (-103); 82 downloader tests pass |
| 2026-06-11 | issue | [issue27-manifest-silent-failures-loud-return-conventions_log.md](docs/devlog/20260611-issue27-manifest-silent-failures-loud-return-conventions_log.md) | Manifest mutations warn+return-false on miss; return conventions documented in all 15 module headers; 6 new tests; 354 total pass |
| 2026-06-11 | issue | [issue29-consolidate-manifest-file-iteration-helpers_log.md](docs/devlog/20260611-issue29-consolidate-manifest-file-iteration-helpers_log.md) | Extracted _filter_files/_reduce_files helpers; refactored 5 public functions to one-liners; 10 new tests; 364 total pass |

| 2026-06-10 | issue | [fix-book-detail-resume-progress-zero_log.md](docs/devlog/20260610-fix-book-detail-resume-progress-zero_log.md) | Fixed book detail resume progress always showing 0%; ported `get_existing_bytes()` + `bytes_downloaded=already_on_disk` + free-space fix from library_browser; 2 new tests; 365 total pass |
| 2026-06-10 | issue | [fix-ebook-audio-download-status-independent_log.md](docs/devlog/20260610-fix-ebook-audio-download-status-independent_log.md) | Fixed ebook download overwriting audio manifest; per-type status tracking in book detail; fixed reconcile_manifest `fs:` crash; 306 tests pass |

| 2026-06-10 | issue | [issue05-download-pipeline-acceptance-audit-gap-close_log.md](docs/devlog/20260610-issue05-download-pipeline-acceptance-audit-gap-close_log.md) | Audited all 13 acceptance criteria; added Open Ebook button + ReaderUI integration; fixed `_itemFromManifest` ebook reconstruction; 309 tests pass |
| 2026-06-09 | issue | [issue05-download-pipeline-tdd-and-ui-wiring_log.md](docs/devlog/20260609-issue05-download-pipeline-tdd-and-ui-wiring_log.md) | Created `absaudio/downloader.lua` with 52 tests across 11 TDD slices; added 5 manifest helpers; rewrote `_addDownloadStatus` with 3-state logic; wired download/delete buttons in library_browser; 262 total pass |

| Date | Type | File | Summary |
|------|------|------|----------|
| 2026-06-10 | issue | [pr22-review-findings-self-contained-book-detail_log.md](docs/devlog/20260610-pr22-review-findings-self-contained-book-detail_log.md) | Made BookDetailView own its download/delete/ebook behavior; fixed all 4 PR #22 review bugs (coroutine discard, self_ref nil, ConfirmBox missing, config:get colon-call); removed ~290 lines dead/duplicated code from dashboard+library_browser; 322 tests pass |
| 2026-06-10 | generic | [dashboard-cover-images_log.md](docs/devlog/20260610-dashboard-cover-images_log.md) | Added cover thumbnails (80×100) to dashboard resume + downloaded books sections; `_buildBookRow()` helper matching library browser layout; gray 🎵 placeholder fallback; 4 new tests; 326 total pass |
| 2026-06-10 | generic | [fix-dashboard-detail-view-missing-action-buttons_log.md](docs/devlog/202610-fix-dashboard-detail-view-missing-action-buttons_log.md) | Dashboard→detail now matches library→detail; wired on_download/on_delete/on_open_ebook callbacks + enriched item data from manifest; added 3 handler methods to DashboardView; 322 tests pass |
| 2026-06-10 | generic | [fix-dashboard-book-tap-cover-cache-nil-crash_log.md](docs/devlog/20260610-fix-dashboard-book-tap-cover-cache-nil-crash_log.md) | Fixed crash on dashboard book tap; added `cover_cache.init()` to `detail.prepare()` with idempotent guard; 311 tests pass |
| 2026-06-10 | generic | [fix-dashboard-download-handlers-crash_log.md](docs/devlog/202610-fix-dashboard-download-handlers-crash_log.md) | Fixed PR review bugs: non-existent `download_single_file`, wrong arg order; rewrote dashboard handlers with correct API (`start_chunked_download`); fixed config shadowing + missing TextWidget face crash; 320 tests pass |
| 2026-06-10 | issue | [fix-ebook-cancel-redownload-crash-nil-id_log.md](docs/devlog/202610-fix-ebook-cancel-redownload-crash-nil-id_log.md) | Fixed crash on ebook re-download after cancel; unwrapped `{item, ebook_only}` envelope in 3 re-push callbacks; 15 library_browser tests pass |
| 2026-06-10 | issue | [fix-ebook-download-stub-never-executes_log.md](docs/devlog/20260610-fix-ebook-download-stub-never-executes_log.md) | Fixed ebook download never executing (TODO stub returned early); unified ebook+audio into shared download pipeline; 282 tests pass |
| 2026-06-10 | issue | [fix-download-resume-resets-to-zero_log.md](docs/devlog/20260610-fix-download-resume-resets-to-zero_log.md) | Fixed resume always starting from zero; skip `prepare_download` for partial downloads (preserves "partial" status); fixed progress display to show already-downloaded bytes; 4 new tests; 77 downloader tests pass |
| 2026-06-10 | issue | [fix-cancel-download-hang-starves-event-loop_log.md](docs/devlog/20260610-fix-cancel-download-hang-starves-event-loop_log.md) | Fixed cancel-download hanging emulator; `scheduleIn(0)` starved UIManager event loop; changed to `scheduleIn(0.05)`; 278 tests pass |
| 2026-06-09 | issue | [fix-yield-across-c-call-boundary-download_log.md](docs/devlog/20260609-fix-yield-across-c-call-boundary-download_log.md) | Fixed `attempt to yield across C-call boundary` in audiobook downloads; created raw socket `chunked_http.lua` module; 6 new tests; 295 total pass |
| 2026-06-09 | issue | [issue19-library-browser-data-render-split_log.md](docs/devlog/20260609-issue19-library-browser-data-render-split_log.md) | Extracted `browser.prepare()` from `show()`; data/render split; eliminated redundant `getItems` in `_addPageNav`; 5 new tests; 163 total pass |
| 2026-06-09 | issue | [issue16-shared-widget-helpers-deduplication_log.md](docs/devlog/20260609-issue16-shared-widget-helpers-deduplication_log.md) | Created `widget_helpers.lua` module; extracted triplicated `format_duration`, `format_time`, `format_file_size`, `addSeparator` from 3 widgets; removed `get_item_title`/`get_item_author` duplicates; 31 new tests; 159 total pass |
| 2026-06-09 | issue | [issue14-book-detail-instance-state-migration_log.md](docs/devlog/20260609-issue14-book-detail-instance-state-migration_log.md) | Migrated `_on_back`/`_on_download` from module-level locals to `self.on_back`/`self.on_download` on BookDetailView; added callback isolation tests; 96 tests pass |
| 2026-06-09 | issue | [issue12-dashboard-instance-state-migration_log.md](docs/devlog/20260609-issue12-dashboard-instance-state-migration_log.md) | Migrated `_on_settings`/`_on_sync_now`/`_on_export_diagnostics` from module-level locals to instance state on DashboardView; added callback isolation tests; 103 tests pass |
| 2026-06-09 | issue | [issue04-acceptance-criteria-audit-gaps-closed_log.md](docs/devlog/20260609-issue04-acceptance-criteria-audit-gaps-closed_log.md) | Audited all 12 acceptance criteria; added `wasLastFetchSuccessful()` + greyed-out offline Browse Library button; created book_detail tests (9); 94 tests pass |
| 2026-06-09 | issue | [issue04-library-browser-search-feature_log.md](docs/devlog/20260609-issue04-library-browser-search-feature_log.md) | Search feature: TDD tests, IconWidget for search button, Lua closure fix, `browser.search()` API; search filtering in emulator still broken |
| 2026-06-09 | issue | [issue04-library-browser-search-partial-repaint-fix_log.md](docs/devlog/20260609-issue04-library-browser-search-partial-repaint-fix_log.md) | Fixed search results rendering as partial overlay; added `UIManager:setDirty("full")` in `_refresh()` |
| 2026-06-08 | issue | [issue04-library-browser-fixes-titles-covers-caching_log.md](docs/devlog/20260608-issue04-library-browser-fixes-titles-covers-caching_log.md) | Fixed Unknown Title (data mapping), cover art (`:`→`.` + lfs loading), recursive mkdir; 75 tests pass |
| 2026-06-08 | issue | [issue04-cover-image-truncation-fix_log.md](docs/devlog/20260608-issue04-cover-image-truncation-fix_log.md) | Fixed truncated cover files (streaming→ltn12.sink.table bulk write); changed Accept header to image/* |
| 2026-06-08 | issue | [issue04-cover-sizing-dynamic-pagination-persistent-caching_log.md](docs/devlog/20260608-issue04-cover-sizing-dynamic-pagination-persistent-caching_log.md) | DPI-scaled covers, dynamic per_page, persistent cover cache, clear-cache button |
| 2026-06-08 | issue | [issue04-library-browser-scrolling-pagination-fix_log.md](docs/devlog/20260608-issue04-library-browser-scrolling-pagination-fix_log.md) | Fixed scrolling (cropping_widget+show_parent pattern) and pagination (Prev/Next nav bar) |
| 2026-06-08 | issue | [issue04-library-browser-book-detail-view_log.md](docs/devlog/20260608-issue04-library-browser-book-detail-view_log.md) | Implemented cover_cache, library_store (data layer), library_browser + book_detail (UI widgets); fixed api.init() never being called |
| 2026-06-08 | issue | [issue03-data-layer-dashboard-wiring-audit-fixes_log.md](docs/devlog/20260608-issue03-data-layer-dashboard-wiring-audit-fixes_log.md) | Audited Issue #3 acceptance criteria, fixed Settings→config dialog wiring, added Sync Now + Export Diagnostics stubs, added getRecentBook tests |
| 2026-06-08 | slice | [dashboard-widget-fullscreen-rendering-fixes_log.md](docs/devlog/20260608-dashboard-widget-fullscreen-rendering-fixes_log.md) | Fixed fullscreen rendering, tap callback crashes, font error, and added back/swipe-to-close for dashboard widget |
| 2026-06-08 | issue | [issue02-slice1-plugin-scaffold-emulator-testing_log.md](docs/devlog/20260608-issue02-slice1-plugin-scaffold-emulator-testing_log.md) | Re-ran Issue #2 with emulator testing; fixed _meta.lua deprecation, set up kodev emulator, verified plugin loads cleanly |

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **absaudio.koplugin** (817 symbols, 834 relationships, 0 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> Index stale? Run `node .gitnexus/run.cjs analyze` from the project root — it auto-selects an available runner. No `.gitnexus/run.cjs` yet? `npx gitnexus analyze` (npm 11 crash → `npm i -g gitnexus`; #1939).

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows. For regression review, compare against the default branch: `detect_changes({scope: "compare", base_ref: "main"})`.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `context({name: "symbolName"})`.

## Never Do

- NEVER edit a function, class, or method without first running `impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `rename` which understands the call graph.
- NEVER commit changes without running `detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/absaudio.koplugin/context` | Codebase overview, check index freshness |
| `gitnexus://repo/absaudio.koplugin/clusters` | All functional areas |
| `gitnexus://repo/absaudio.koplugin/processes` | All execution flows |
| `gitnexus://repo/absaudio.koplugin/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->

# DOX framework

- DOX is highly performant AGENTS.md hierarchy installed here
- Agent must follow DOX instructions across any edits

## Core Contract

- AGENTS.md files are binding work contracts for their subtrees
- Work products, source materials, instructions, records, assets, and durable docs must stay understandable from the nearest applicable AGENTS.md plus every parent AGENTS.md above it

## Read Before Editing

1. Read the root AGENTS.md
2. Identify every file or folder you expect to touch
3. Walk from the repository root to each target path
4. Read every AGENTS.md found along each route
5. If a parent AGENTS.md lists a child AGENTS.md whose scope contains the path, read that child and continue from there
6. Use the nearest AGENTS.md as the local contract and parent docs for repo-wide rules
7. If docs conflict, the closer doc controls local work details, but no child doc may weaken DOX

Do not rely on memory. Re-read the applicable DOX chain in the current session before editing.

## Update After Editing

Every meaningful change requires a DOX pass before the task is done.

Update the closest owning AGENTS.md when a change affects:

- purpose, scope, ownership, or responsibilities
- durable structure, contracts, workflows, or operating rules
- required inputs, outputs, permissions, constraints, side effects, or artifacts
- user preferences about behavior, communication, process, organization, or quality
- AGENTS.md creation, deletion, move, rename, or index contents

Update parent docs when parent-level structure, ownership, workflow, or child index changes. Update child docs when parent changes alter local rules. Remove stale or contradictory text immediately. Small edits that do not change behavior or contracts may leave docs unchanged, but the DOX pass still must happen.

## Hierarchy

- Root AGENTS.md is the DOX rail: project-wide instructions, global preferences, durable workflow rules, and the top-level Child DOX Index
- Child AGENTS.md files own domain-specific instructions and their own Child DOX Index
- Each parent explains what its direct children cover and what stays owned by the parent
- The closer a doc is to the work, the more specific and practical it must be

## Child Doc Shape

- Create a child AGENTS.md when a folder becomes a durable boundary with its own purpose, rules, responsibilities, workflow, materials, or quality standards
- Work Guidance must reflect the current standards of the project or user instructions; if there are no specific standards or instructions yet, leave it empty
- Verification must reflect an existing check; if no verification framework exists yet, leave it empty and update it when one exists

Default section order:
- Purpose
- Ownership
- Local Contracts
- Work Guidance
- Verification
- Child DOX Index

## Style

- Keep docs concise, current, and operational
- Document stable contracts, not diary entries
- Put broad rules in parent docs and concrete details in child docs
- Prefer direct bullets with explicit names
- Do not duplicate rules across many files unless each scope needs a local version
- Delete stale notes instead of explaining history
- Trim obvious statements, repeated rules, misplaced detail, and warnings for risks that no longer exist

## Closeout

1. Re-check changed paths against the DOX chain
2. Update nearest owning docs and any affected parents or children
3. Refresh every affected Child DOX Index
4. Remove stale or contradictory text
5. Run existing verification when relevant
6. Report any docs intentionally left unchanged and why

## User Preferences

When the user requests a durable behavior change, record it here or in the relevant child AGENTS.md

## Child DOX Index

| Path | Scope |
|------|-------|
| `absaudio/AGENTS.md` | UI widgets, navigation, download pipeline, data stores |
| `spec/AGENTS.md` | Test suite: mock framework, per-module tests, runner conventions |
| `docs/AGENTS.md` | Project documentation: spec, PRD, ADRs, dev logs, data models |
