# API Contract — ABS Audio Plugin

## Authentication

All requests use `Authorization: Bearer <token>` header. GET requests can also pass `?token=<token>` as a query parameter (used for file downloads).

## Endpoints

| # | Method | Endpoint | Purpose | Request Body | Response |
|---|--------|----------|---------|-------------|----------|
| 1 | GET | `/api/libraries` | List all libraries | — | `{libraries: [{id, name, mediaType, ...}]}` |
| 2 | GET | `/api/libraries/:id/items?limit=&page=&sort=&desc=&search=&filter=` | List items in library | — | `{results: [...], total: N}` |
| 3 | GET | `/api/items/:id?expanded=1` | Get item details + audio files + chapters | — | Item with `media.audioFiles`, `media.chapters` |
| 4 | GET | `/api/items/:id/file/:ino?token=` | Download specific file (binary stream) | — | Binary file data |
| 5 | GET | `/api/me/progress/:id` | Get progress for item | — | `{currentTime, duration, progress, isFinished, ...}` or 404 |
| 6 | PATCH | `/api/me/progress/:id` | Update progress | `{currentTime, duration, progress, isFinished}` | 200 OK |
| 7 | GET | `/api/me/items-in-progress?limit=` | Get items with progress | — | `{libraryItems: [...]}` |
| 8 | GET | `/api/items/:id/cover` | Get cover image (JPEG/WebP) | — | Binary image data |

## Error Handling

Every API call returns `ok, result_or_error`:
- **Success**: `ok = true`, `result = parsed JSON table`
- **Failure**: `ok = false`, `error = {type, status_code, message}`

HTTP status code mapping:
- `401/403` → `auth` → "Check your server URL and API token in Settings."
- `404` → `not_found` → "Item not found on server. It may have been removed."
  - Exception: 404 on progress GET → returns `nil` silently (expected state)
- `429` → `api` → "Too many requests. Please wait and try again."
- `5xx` → `server` → "Server error. Please try again later." (retried with backoff)
- Malformed JSON → `parse` → "Unexpected response from server."

## Retry Behavior

All read endpoints (GET) retry on server errors (5xx) and network failures:
- **Max retries**: 3
- **Initial delay**: 1 second
- **Backoff multiplier**: 2x (delays: 1s, 2s, 4s)
- Progress GET and cover GET do NOT retry (single attempt)

## Timeouts

| Operation | Connect Timeout | Request Timeout |
|-----------|----------------|-----------------|
| API calls | 10s | 15s |
| File downloads | 10s | 30s |
| Cover images | 10s | 30s |

## Implementation

All endpoints are implemented in `api.lua` with:
- `pcall` wrapping on every HTTP request (no unhandled crashes)
- `socketutil:set_timeout()` / `socketutil:reset_timeout()` for timeout management
- `ltn12.sink.table()` for response body collection
- `json.decode()` for response parsing (KOReader's built-in dkjson)

## ABS Data Shapes (as used by the plugin)

### Library
```
{id, name, mediaType: "book"|"podcast", folders: [...], settings: {...}}
```

### Library Item
```
{id, ino, libraryId, mediaType, media: {
  metadata: {title, authorName, narratorName, ...},
  audioFiles: [{index, ino, metadata: {filename, ext, size}, duration, ...}],
  chapters: [{id: int, start: float, end: float, title: string}],
  duration: float
}}
```

### Media Progress
```
{id, libraryItemId, currentTime: float, duration: float,
 progress: float (0-1), isFinished: boolean, lastUpdate: int (ms)}
```

### Book Chapter
```
{id: int, start: float (seconds), end: float (seconds), title: string}
```
