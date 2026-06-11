# Fix: Audiobook download fails with "attempt to yield across C-call boundary"

> **Date:** 2026-06-09
> **Type:** issue
> **Reference:** User-reported runtime error from KOReader device logs

## Goal

Fix audiobook downloads that fail with `attempt to yield across C-call boundary` at `downloader.lua:608`. The `start_chunked_download` function used `coroutine.yield()` inside an ltn12 sink callback, which is invoked by `socket.http.request()` — a C function wrapped in `socket.protect(pcall)`. Yielding across a C-call boundary is impossible in Lua 5.1/LuaJIT.

Files can be up to 1.8 GB, so progress updates during a single file download are mandatory.

## What Was Done

- Diagnosed root cause: `socket.http.request()` → `socket.protect(pcall)` → `ltn12.pump.all` → sink callback → `coroutine.yield()` crosses C-frame boundary
- Created `absaudio/chunked_http.lua` — a raw socket HTTP client that bypasses `socket.http.request` entirely, reading body chunks via `sock:receive(chunk_size)` and yielding between reads in pure Lua context
- Modified `start_chunked_download` in `absaudio/downloader.lua` to use `chunked_http.download()` instead of `api.downloadFile()`
- Added `api.getDownloadUrl(item_id, ino)` to `api.lua` for URL construction
- Added auto-initialization in `chunked_http` (lazy-loads socket/ssl modules)
- Updated 4 existing tests in `spec/test_downloader.lua` for new deps interface
- Created `spec/test_chunked_http.lua` with 6 tests (HTTPS, HTTP, yield-between-chunks, 404, connection failure, uninitialized)
- All 295 tests pass (6 new + 289 existing)

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Raw socket HTTP client instead of patched luasocket | `socket.protect` and `socket.newtry` are C functions baked into the `.so` binary — cannot be replaced. The only way to yield safely is to bypass `socket.http.request` entirely. |
| Yield between `sock:receive()` calls, not inside callbacks | After `sock:receive()` returns, the C-frame is gone. `coroutine.yield()` at that point is pure Lua → safe. |
| 32 KB default chunk size | Balances throughput (fewer syscalls) against UI responsiveness (yield every 32KB = frequent progress updates even for slow connections). |
| Auto-initialize `chunked_http` on first `download()` call | Avoids requiring explicit `init()` in `main.lua`; the module lazy-loads `socket`/`ssl` via `pcall(require, ...)`. |
| `pcall` wraps individual socket operations, NOT the yield | `pcall(sock:receive)` is fine — the C-frame exits when pcall returns. `coroutine.yield()` is called after pcall returns, in pure Lua context. |
| Custom URL parser instead of depending on `socket.url` | `socket.url` requires `socket` C module to load; `parse_url` is simple enough to do with string patterns. Keeps the module self-contained. |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| `attempt to yield across C-call boundary` | `socket.http.request` wraps everything in `socket.protect(pcall)`. The ltn12 sink callback (which yields) is called from within that C frame. | Bypassed `socket.http.request` entirely; raw socket I/O with manual HTTP request construction. |
| `string:startswith()` not available in standard Lua | Used `host_port:startswith("[")` for IPv6 check — `startswith` is a KOReader extension, not standard Lua. | Changed to `host_port:sub(1, 1) == "["` |
| Mock socket `_state` on `self` lost after SSL wrap | Test mock stored `_state` on the socket table; `ssl.wrap()` returned a new table, breaking the state machine. | Used a simple `state` counter variable captured by closure instead of storing on `self`. |

## Files Changed

| File | Change Summary |
|------|---------------|
| `absaudio/chunked_http.lua` | **New** — Raw socket HTTP client with yield-safe chunk reading (TLS, redirects, chunked TE, content-length, connection-close modes) |
| `absaudio/downloader.lua` | `start_chunked_download` rewritten: uses `chunked_http.download()` instead of `api.downloadFile()` + ltn12 yielding sink |
| `api.lua` | Added `api.getDownloadUrl(item_id, ino)` — builds full download URL with token |
| `spec/test_chunked_http.lua` | **New** — 6 tests: HTTPS download, HTTP download, yield-between-chunks, 404 error, connection failure, uninitialized state |
| `spec/test_downloader.lua` | Updated 4 `start_chunked_download` tests: replaced `deps.api.downloadFile` with `deps.api.getDownloadUrl` + `deps.chunked_http` mock |

## Open Items & Next Steps

- [ ] Test on actual KOReader device with real ABS server to verify TLS handshake works end-to-end
- [ ] Consider adding a timeout/keepalive mechanism for very large files on slow connections (currently `sock:settimeout(30)`)
- [ ] The `execute_download` and `execute_single_file_download` paths still use `api.downloadFile` (blocking, no progress) — could be migrated to `chunked_http` for consistency
- [ ] `Range` header for resume is set in `start_chunked_download` but `chunked_http` doesn't validate partial content (206) response — currently treated as regular response

---

*Log written by write-log skill*
