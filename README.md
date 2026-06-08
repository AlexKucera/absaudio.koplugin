# ABS Audio — KOReader Plugin for PocketBook Era Color

A KOReader plugin that connects to a self-hosted [Audiobookshelf](https://www.audiobookshelf.org/) (ABS) server. Browse your audiobook library, download files with resume support, play them on-device via inkview FFI, and sync playback position across devices.

**Status:** Slice 1 in progress. See [PRD](docs/prd/PRD.md) for full specification.

## Documentation

| Document | Description |
|---|---|
| [PRD](docs/prd/PRD.md) | Product Requirements Document — 42 user stories, architecture, data model |
| [Spec](docs/spec/absaudio-plugin-spec.md) | Technical research spec — ABS API analysis, inkview API survey, upstream plugin analysis |
| [Glossary](docs/glossary/CONTEXT.md) | Domain glossary — 29 resolved terms |
| [ADRs](docs/adr/) | Architectural Decision Records (6 so far) |

## Prerequisites

- **KOReader** v2024.11 or later (tested with emulator build v2026.03)
- **Audiobookshelf** v2.x server with API access
- **Target device:** PocketBook Era Color (emulator testing available on macOS/Linux)

## Installation

### On Device

1. Copy the `absaudio.koplugin/` directory to your KOReader plugins folder:
   ```
   /mnt/ext1/.adds/koreader/plugins/absaudio.koplugin/
   ```
2. Restart KOReader
3. The plugin appears under **Plugins → ABS Audio** in the hamburger menu

### Emulator Setup (macOS)

For development and testing without a physical device:

```bash
# 1. Clone and build KOReader (if not already done)
git clone https://github.com/koreader/koreader.git
cd koreader
./kodev build

# 2. Symlink the plugin into KOReader's plugins directory
ln -sf /path/to/absaudio.koplugin koreader/plugins/absaudio.koplugin

# 3. Run the emulator (requires GNU getopt and GNU make)
#    macOS: brew install gnu-getopt make
PATH="/opt/homebrew/opt/gnu-getopt/bin:/opt/homebrew/opt/make/libexec/gnubin:$PATH" \
  ./kodev run -W 600 -H 800 -D 212
```

The emulator opens a desktop window simulating a 600×800 e-reader at 212 DPI. Plugin logs appear in the terminal.

#### Testing Individual Widgets

```bash
./kodev wbuilder
```

Opens KOReader's widget builder for testing individual UI components (settings dialog, dashboard) in isolation without loading the full reader.

## Configuration

| Setting | Default | Description |
|---|---|---|
| `server` | *(required)* | ABS server URL (e.g. `https://abs.example.com`) |
| `token` | *(required)* | API key from ABS → Settings → API Keys |
| `download_dir` | *(prompted)* | Base directory for downloaded audiobooks |
| `preferred_format` | `m4b` | Audio format preference (`m4b`, `mp3`) |
| `log_level` | `verbose` | Logging verbosity (`verbose`, `info`, `warn`) |

On first run, the settings dialog opens automatically. Enter your ABS server URL and API token. The plugin validates credentials by calling `GET /api/libraries` before saving.

## Logger Output

- **Emulator:** Logs appear in the terminal where `./kodev run` was executed
- **Device:** Logs go to `crash.log` in the KOReader directory

Log levels: `logger.dbg()` (verbose), `logger.info()` (info), `logger.warn()` (warn), `logger.err()` (error)

## Scope (v1)

- **Device:** PocketBook Era Color only
- **Server:** Audiobookshelf v2.x
- **Features:** Browse library, download audio+PDF/ebook, playback with chapters/speed/sleep timer, bidirectional progress sync

## Build from scratch

This plugin is built from scratch using `naleo/audiobookshelf.koplugin` as reference material (not a code fork). See [ADR-0006](docs/adr/0006-from-scratch-not-fork.md) for rationale.

## Running Unit Tests

Pure-logic tests run with standard Lua (no KOReader needed):

```bash
lua spec/test_config.lua
lua spec/test_logger.lua
lua spec/test_error_handler.lua
```

Or with LuaJIT (matching KOReader's runtime):

```bash
luajit spec/test_config.lua
luajit spec/test_logger.lua
luajit spec/test_error_handler.lua
```

## License

See [LICENSE.md](LICENSE.md).
