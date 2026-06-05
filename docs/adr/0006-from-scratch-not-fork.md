# From-scratch implementation, not a fork of naleo's plugin

Status: accepted

The plugin is built from scratch using `naleo/audiobookshelf.koplugin` as reference material only — not as a git fork or code base to modify.

Rationale: the original plan was to fork naleo's ~600-line plugin and make surgical changes (remove 2 ebook filters, change 1 post-download action). After full design, the actual scope is ~2080 lines of new/heavily-rewritten code against ~140 lines of reusable patterns (~93% new). The modules that remain (browser, detail view, download widget) are so fundamentally different in architecture (dashboard root vs library root, adaptive two-mode detail view vs single-mode, coroutine chunked download vs synchronous blocking) that rewriting from scratch is cleaner than carrying forward naming conventions and structural decisions made for a different problem.

What we still take from naleo: `_meta.lua` plugin descriptor template, proof that `socketutil` + Bearer token auth works on PocketBook KOReader, ABS endpoint URL patterns and response shapes, `MultiInputDialog` settings pattern, `LuaSettings` config file pattern.

Considered alternatives: Git fork (carries ~600 lines of code where 93% needs rewriting), copy-paste then modify (same problem without git traceability).
