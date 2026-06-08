<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **absaudio.koplugin** (273 symbols, 265 relationships, 0 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `gitnexus_detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.

## Never Do

- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `gitnexus_rename` which understands the call graph.
- NEVER commit changes without running `gitnexus_detect_changes()` to check affected scope.

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

## Session Logs

Session logs are written to `docs/devlog/` after each completed task, issue fix, or milestone.
They capture what was done, decisions & rationale, gotchas & fixes, and next steps. Before starting a new session, read the previous session logs.

<!-- write-log: session-log-index -->

| Date | Type | File | Summary |
|------|------|------|----------|
| 2026-06-08 | issue | [issue04-library-browser-fixes-titles-covers-caching_log.md](docs/devlog/20260608-issue04-library-browser-fixes-titles-covers-caching_log.md) | Fixed Unknown Title (data mapping), cover art (`:`→`.` + lfs loading), recursive mkdir; 75 tests pass |
| 2026-06-08 | issue | [issue04-cover-image-truncation-fix_log.md](docs/devlog/20260608-issue04-cover-image-truncation-fix_log.md) | Fixed truncated cover files (streaming→ltn12.sink.table bulk write); changed Accept header to image/* |
| 2026-06-08 | issue | [issue04-library-browser-book-detail-view_log.md](docs/devlog/20260608-issue04-library-browser-book-detail-view_log.md) | Implemented cover_cache, library_store (data layer), library_browser + book_detail (UI widgets); fixed api.init() never being called |
| 2026-06-08 | issue | [issue03-data-layer-dashboard-wiring-audit-fixes_log.md](docs/devlog/20260608-issue03-data-layer-dashboard-wiring-audit-fixes_log.md) | Audited Issue #3 acceptance criteria, fixed Settings→config dialog wiring, added Sync Now + Export Diagnostics stubs, added getRecentBook tests |
| 2026-06-08 | slice | [dashboard-widget-fullscreen-rendering-fixes_log.md](docs/devlog/20260608-dashboard-widget-fullscreen-rendering-fixes_log.md) | Fixed fullscreen rendering, tap callback crashes, font error, and added back/swipe-to-close for dashboard widget |
| 2026-06-08 | issue | [issue02-slice1-emulator-testing_log.md](docs/devlog/20260608-issue02-slice1-plugin-scaffold-emulator-testing_log.md) | Re-ran Issue #2 with emulator testing; fixed _meta.lua deprecation, set up kodev emulator, verified plugin loads cleanly |
<!-- write-log: session-log-index-end -->
