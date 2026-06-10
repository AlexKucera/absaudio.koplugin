# docs/ — Project Documentation

## Purpose

Persistent project documentation: planning spec, PRD, architecture decision records, development session logs, API contracts, and data models. This is the historical record and reference material for the project.

## Ownership

Documentation is organized by type into subdirectories. Each subdirectory has a distinct purpose:

- `adr/` — Architecture Decision Records (numbered, status: accepted/superseded)
- `devlog/` — Development session logs (one per issue/fix, dated `YYYYMMDD-<slug>.md`)
- `spec/` — Planning specification (the original project spec)
- `prd/` — Product requirements document
- `session-notes/` — Early session summaries from project inception

Top-level docs:
- `api-contract.md` — ABS API endpoint reference with request/response shapes
- `manifest-data-model.md` — Local manifest entry schema and field descriptions

## Local Contracts

### Architecture Decision Records (`adr/`)
- Numbered sequentially: `NNNN-<slug>.md`
- Each contains: Title, Status, Context, Decision, Consequences
- Status values: `accepted`, `superseded`, `deprecated`
- Current ADRs: global position in manifest, playlist model for playback, sync conflict resolution, dashboard as root navigation, coroutine chunked download, from-scratch-not-fork

### Dev logs (`devlog/`)
- One file per issue fix or milestone, dated with `YYYYMMDD-<slug>` naming
- Standard sections: What was done, Decisions & rationale, Gotchas & fixes, Next steps
- Session log index is maintained in root AGENTS.md
- Dev logs are the primary source for distilling learnings back into AGENTS.md

### Spec (`spec/`)
- `absaudio-plugin-spec.md` — the original planning spec that drives feature development
- This is the authoritative reference for v1 scope and feature behavior

## Work Guidance

- Add a new ADR when making a significant architectural decision
- Write a dev log after each coding session that resolves an issue or completes a milestone (trigger: "write log")
- Run `distill learnings` periodically to extract generalizable knowledge from dev logs into root AGENTS.md
- Update `api-contract.md` when ABS API integration changes
- Update `manifest-data-model.md` when the local manifest schema changes

## Verification

- No automated checks on docs — review for accuracy when updating
- Session log index in root AGENTS.md should list all devlog files chronologically

## Child DOX Index

No child AGENTS.md files — subdirectories are organized by document type, not by ownership boundary. All content is governed by this single doc.
