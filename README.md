# ABS Audio — KOReader Plugin for PocketBook Era Color

A KOReader plugin that connects to a self-hosted [Audiobookshelf](https://www.audiobookshelf.org/) (ABS) server. Browse your audiobook library, download files with resume support, play them on-device via inkview FFI, and sync playback position across devices.

**Status:** In design phase. See [PRD](docs/prd/PRD.md) for full specification.

## Documentation

| Document | Description |
|---|---|
| [PRD](docs/prd/PRD.md) | Product Requirements Document — 42 user stories, architecture, data model |
| [Spec](docs/spec/absaudio-plugin-spec.md) | Technical research spec — ABS API analysis, inkview API survey, upstream plugin analysis |
| [Glossary](docs/glossary/CONTEXT.md) | Domain glossary — 29 resolved terms |
| [ADRs](docs/adr/) | Architectural Decision Records (6 so far) |

## Scope (v1)

- **Device:** PocketBook Era Color only
- **Server:** Audiobookshelf v2.x
- **Features:** Browse library, download audio+PDF/ebook, playback with chapters/speed/sleep timer, bidirectional progress sync

## Build from scratch

This plugin is built from scratch using `naleo/audiobookshelf.koplugin` as reference material (not a code fork). See [ADR-0006](docs/adr/0006-from-scratch-not-fork.md) for rationale.

## License

See [LICENSE.md](LICENSE.md).
