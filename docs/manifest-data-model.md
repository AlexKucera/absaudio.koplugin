# Manifest Data Model — ABS Audio Plugin

## Overview

The manifest tracks all downloaded/in-progress audiobooks on the local device. It's the single source of truth for local state, backed by KOReader's `LuaSettings` (stored as a Lua table in `{settings_dir}/absaudio_manifest.lua`).

## Entry Schema

Each book is keyed by its ABS `item_id` under the `books` setting:

```lua
{
  abs_item_id    = string,   -- ABS library item ID (e.g. "li_abc123")
  title          = string,   -- Book title
  author         = string,   -- Author name
  local_dir      = string,   -- Local folder path (e.g. "/mnt/ext1/audiobooks/Author_Title/")
  files          = {         -- Ordered array of all files for this book
    {
      filename = string,     -- Sanitized filename (e.g. "Book_Title.m4b")
      size     = number,     -- File size in bytes
      type     = string,     -- "audio" or "ebook"
      status   = string,     -- "complete", "partial", or "pending"
    }
  },
  current_time   = number,   -- Global position in seconds from start (ABS-compatible scalar)
  duration       = number,   -- Total duration in seconds
  chapters       = {         -- Array of chapter markers from ABS
    {
      id    = number,        -- Chapter ID
      title = string,        -- Chapter title
      start = number,        -- Start time in seconds
      ["end"] = number,      -- End time in seconds
    }
  },
  is_finished    = boolean,  -- Whether the book has been completed
  last_synced_at = number,   -- Unix timestamp of last sync with ABS
}
```

## File Status Lifecycle

```
pending → partial → complete
   ↑          │
   └──────────┘  (re-download after failure)
```

- **`pending`**: File not yet downloaded (initial state for new books)
- **`partial`**: Download started but not completed (WiFi drop, crash, etc.)
- **`complete`**: File fully downloaded and verified

On plugin startup, the manifest is reconciled against actual files on disk: if a file's actual size doesn't match the expected size, its status is set to `partial`.

## Entry Lifecycle

### Created (download initiated)
1. User selects a book from the library browser
2. `manifest.addBook(entry)` creates a new entry with all files in `pending` status
3. As each file downloads, `manifest.updateFileStatus()` updates individual files

### Updated (during playback/sync)
- `manifest.updatePosition(abs_item_id, current_time, is_finished)` — after each sync or position change
- `manifest.updateBook(abs_item_id, updates)` — for arbitrary field updates
- `manifest.updateFileStatus(abs_item_id, filename, status)` — after download completion

### Deleted (user removes book)
1. User selects "Delete" from book detail view
2. `manifest.removeBook(abs_item_id)` removes the entry
3. Local files are deleted from disk (handled by caller, not manifest)

## Public API

| Function | Description |
|----------|-------------|
| `manifest.init()` | Initialize the store (idempotent, creates if missing) |
| `manifest.addBook(entry)` | Add a new book entry |
| `manifest.getBook(abs_item_id)` | Get a single book by ID, or `nil` |
| `manifest.getAllBooks()` | Get all books as an array |
| `manifest.updateBook(abs_item_id, updates)` | Partial update (merges fields) |
| `manifest.removeBook(abs_item_id)` | Delete a book entry |
| `manifest.updateFileStatus(abs_item_id, filename, status)` | Update one file's download status |
| `manifest.updatePosition(abs_item_id, current_time, is_finished)` | Update playback position |
| `manifest.getRecentBook()` | Get the most recently played book (highest `current_time`) |

## Dashboard Usage

- **Resume Last Book**: `manifest.getRecentBook()` → returns book with highest `current_time`
- **Downloaded Books list**: `manifest.getAllBooks()` → shows all entries with progress badges
- **Progress badge**: `format_progress(current_time, duration)` → "42% · 2h 30m / 6h 0m"
- **Incomplete download badge**: Files with `partial` or `pending` status show "⚠ Resume download"
