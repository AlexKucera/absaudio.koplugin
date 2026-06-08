# Issue #2: Slice 1 — Plugin scaffold + Config + Settings + First-run experience

> **Date:** 2026-06-08
> **Type:** issue
> **Reference:** [GitHub Issue #2](https://github.com/AlexKucera/absaudio.koplugin/issues/2)

## Goal

Re-run Issue #2 with the updated emulator testing instructions. The issue was updated to include KOReader desktop emulator setup and testing details. Existing code (from a prior session) needed verification against the new acceptance criteria, and the emulator itself needed to be set up and the plugin tested inside it.

## What Was Done

- Verified all 25 existing unit tests pass under both `lua` 5.5 and `luajit` 2.1 (config: 12, logger: 7, error_handler: 6)
- Installed `luajit` via Homebrew (KOReader runtime uses LuaJIT, not PUC-Rio Lua)
- Set up KOReader emulator at `/Users/alex/Projects/scripting/koreader-plugins/koreader` (already checked out and built)
- Symlinked plugin into emulator: `ln -sf /absaudio.koplugin koreader/plugins/absaudio.koplugin`
- Discovered macOS requires GNU `getopt` and GNU `make` on PATH for `kodev run` to work
- Fixed `_meta.lua` — removed deprecated `name` and `version` fields that caused `WARN PluginLoader: absaudio name in _meta.lua, is deprecated`
- Verified plugin loads cleanly in emulator: `Plugin loaded absaudio`, `[ABS] ABSAudio plugin initializing`, `FM loaded plugin absaudio`
- Rewrote `README.md` with: prerequisites, on-device installation, emulator setup (macOS), widget testing (`kodev wbuilder`), config reference table, logger output docs, unit test instructions
- Updated GitNexus index (197 symbols, 188 relationships)

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Removed `name` and `version` from `_meta.lua` | KOReader now derives plugin name from directory name; keeping `name` field produces a deprecation warning in current KOReader builds |
| Require GNU `getopt` + GNU `make` on macOS | macOS ships BSD `getopt` (no long opts) and GNU Make 3.81 (too old for KOReader's build); both need Homebrew versions on PATH |
| Run unit tests under both `lua` and `luajit` | KOReader uses LuaJIT; ensuring tests pass under both runtimes catches any dialect-specific issues early |

## Gotchas & Fixes

| Problem | Root Cause | Fix |
|---------|------------|-----|
| `kodev run` failed with "unsupported getopt version" | macOS ships BSD `getopt` which doesn't support long options | Prepend `/opt/homebrew/opt/gnu-getopt/bin` to PATH |
| `kodev run` failed with "make version too old: 3.81, need 4.1" | macOS ships GNU Make 3.81 | Prepend `/opt/homebrew/opt/make/libexec/gnubin` to PATH |
| Emulator showed `WARN PluginLoader: absaudio name in _meta.lua, is deprecated` | `_meta.lua` included `name = "absaudio"` field, deprecated in current KOReader | Removed `name` and `version` fields; directory name is now the identifier |
| `npx gitnexus analyze` failed with FTS/Binder exception | Stale `.gitnexus` index with missing FTS extension | `rm -rf .gitnexus` then `gitnexus analyze` (global install) |

## Files Changed

| File | Change Summary |
|------|---------------|
| `_meta.lua` | Removed deprecated `name` and `version` fields; plugin name now derived from directory |
| `README.md` | Major rewrite: added prerequisites, install instructions, emulator setup, config reference, logger docs, unit test instructions |
| `AGENTS.md` | GitNexus symbol count updated (179→197 symbols, 170→188 edges) |
| `CLAUDE.md` | GitNexus symbol count updated (same as AGENTS.md) |

## Open Items & Next Steps

- [ ] Commit all untracked files (`main.lua`, `config.lua`, `abs_logger.lua`, `error_handler.lua`, `_meta.lua`, `absaudio/dashboard_widget.lua`, `spec/`) — currently uncommitted
- [ ] Manual emulator test: open plugin menu → trigger first-run settings → enter real ABS credentials → verify API call
- [ ] Manual emulator test: verify dashboard shows 4 sections after successful config save
- [ ] Consider adding `luacheckrc` for linting (noted in CONTEXT.md as missing)
- [ ] Issue #10 (`docs/` mkdocs nav structure) — placeholder exists but may need refinement

---

*Log written by write-log skill*
