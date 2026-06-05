# PocketBook Era + Audiobookshelf session notes

This document bundles the main findings from the session about using a PocketBook Era with Audiobookshelf, KOReader, and related community tooling.

## User goal

The core goal was to find an easy way to get audiobooks from an Audiobookshelf server onto a PocketBook Era, ideally with some kind of position sync, without requiring full streaming support on the device.

## Main findings

### Native PocketBook support

PocketBook Era supports local audiobook playback for common file formats, but there is no native Audiobookshelf client for PocketBook firmware and no first-party support for direct Audiobookshelf integration.[1][2][3]

That means the stock PocketBook path is local files copied or downloaded onto the device, then played with the built-in PocketBook audio player.[2][1]

### KOReader on PocketBook Era

KOReader can be installed on PocketBook devices, including the Era, using the PocketBook build of KOReader.[4][5][6]

This makes KOReader a realistic extension point for custom functionality, plugins, and alternate reading workflows on the Era.[5][7]

### Audiobookshelf support on e-readers

Audiobookshelf manages audiobooks, podcasts, and ebooks, but it does not provide a native PocketBook client or an OPDS-based e-reader integration that would make PocketBook browsing/downloading trivial out of the box.[8][9][10]

Audiobookshelf’s own guidance around API keys shows that it supports script and automation access through Bearer-token authentication, which makes custom integrations plausible.[11]

### Downloading from ABS to PocketBook

For the specific use case of getting audiobooks from Audiobookshelf onto a PocketBook, there is no known ready-made PocketBook solution that directly logs into Audiobookshelf and downloads audiobooks natively on the device.[9][12][1]

The most practical out-of-the-box workaround remains downloading files elsewhere and transferring them to the PocketBook, or building a custom KOReader-side integration.[12][13]

### Progress sync

Native PocketBook playback does not have a known integration that syncs audiobook playback position back to Audiobookshelf.[14][15]

However, there are community tools around KOReader and Audiobookshelf that address adjacent problems, especially ebook reading position sync and audiobook-to-ebook position bridging.[16][17][14]

## Relevant community projects

### audiobook.koplugin

The `audiobook.koplugin` project is relevant because it adds audiobook-oriented playback features to KOReader, including PocketBook-oriented support and local playback functionality.[18][19]

This makes it a strong candidate for reuse as the playback layer in a custom PocketBook/KOReader Audiobookshelf integration rather than building an audio engine from scratch.[18]

### abs-kosync-bridge

The `abs-kosync-bridge` project is a server-side bridge designed to synchronize progress between Audiobookshelf and KOReader/KoSync workflows.[14][16]

Its value is mainly in progress translation and sync logic rather than direct audiobook download to PocketBook. It appears especially useful for listen-in-Audiobookshelf / continue-reading-in-KOReader workflows.[17][14]

This means it likely reduces the amount of custom sync logic needed in a PocketBook plugin, but it does not replace the need for an on-device downloader/browser if the goal is direct audiobook transfer from ABS to PocketBook.[20][14]

## Feasibility of building a custom KOReader plugin

Building a small KOReader plugin for Audiobookshelf was assessed as feasible and roughly a medium-complexity hobby project, especially if the scope is kept narrow: authenticate to ABS, list books, download a selected audiobook, hand it to a local player, and sync progress back where possible.[7][21][22]

KOReader’s plugin model is Lua-based and relatively approachable for scripting-oriented development, and there are existing plugin examples and third-party integrations that provide useful patterns.[23][24][25][7]

The hardest part is likely not HTTP or menu UI, but PocketBook-specific playback integration and reliable progress synchronization semantics.[19][21][22][18]

## Proposed plugin architecture

A sensible MVP architecture discussed in the session was:

- `absaudio.koplugin/_meta.lua`
- `absaudio.koplugin/main.lua`
- `absaudio.koplugin/abs_client.lua`
- `absaudio.koplugin/state.lua`
- `absaudio.koplugin/downloads.lua`
- `absaudio.koplugin/player_adapter.lua`
- `absaudio.koplugin/progress_sync.lua`

The idea was to keep the plugin thin: use Audiobookshelf API keys for auth, maintain a local manifest for downloaded books and progress, reuse an existing KOReader/PocketBook-capable playback layer if possible, and push progress updates to Audiobookshelf on interval and state changes.[21][22][26][11][18]

## Recommended path forward

The most practical strategy emerging from the session was:

1. Install KOReader on the PocketBook Era.[4][5]
2. Evaluate whether `audiobook.koplugin` can serve as the playback layer.[19][18]
3. Run `abs-kosync-bridge` server-side if cross-format audiobook-to-ebook progress sync is desired.[16][14]
4. Build only the missing thin layer: Audiobookshelf login, browse, download, and local PocketBook/KOReader handoff.[27][11]

This avoids duplicating the hardest sync logic while still moving toward the original goal of easy transfer from Audiobookshelf to the PocketBook Era.[14][16][18]

## Notes on the provided plugin skeleton

A starter KOReader plugin skeleton was drafted in the session, including `_meta.lua`, `main.lua`, `abs_client.lua`, `state.lua`, `downloads.lua`, `player_adapter.lua`, and `progress_sync.lua`.

That skeleton was intentionally conceptual rather than production-ready. It was designed to show module boundaries and development direction, not to guarantee immediate drop-in compatibility with current KOReader internals or ABS endpoint behavior.

## Session takeaway

The final practical takeaway was:

- PocketBook Era is viable for local audiobook playback, but not as a native Audiobookshelf client.[3][1][2]
- Easy direct downloading from ABS to PocketBook probably requires custom work.[1][12]
- A custom KOReader plugin is feasible if kept small and if existing community projects are reused instead of reimplemented.[7][23][18]
- `abs-kosync-bridge` is especially promising as a complement to such a plugin, because it already tackles a large part of the sync problem.[17][16][14]

Sources
[1] Audiobooks on Era https://www.reddit.com/r/pocketbook/comments/12v0wkn/audiobooks_on_era/
[2] PocketBook Era: Lesen und Hören - Blog der Stadtbibliothek Erlangen https://blog.stadtbibliothek-erlangen.de/pocketbook-era-lesen-und-hoeren/
[3] Audiobooks on PocketBooks (verse pro, era, etc) https://www.mobileread.com/forums/showthread.php?t=364724
[4] How to Install KOReader on Pocketbook eReaders https://blog.the-ebook-reader.com/2020/09/07/how-to-install-koreader-on-pocketbook-ereaders/
[5] Pocketbook Era With Koreader | tc3 https://www.turbocache3000.de/posts/pocketbook-era-with-koreader/
[6] KOReader on Pocketbook Era: not listed as an app https://www.mobileread.com/forums/showthread.php?p=4543274
[7] Development Guide - KOReader Documentation https://koreader.rocks/doc/topics/Development_guide.md.html
[8] [Enhancement]: Support OPDS to allow eReaders to directly download books · Issue #1953 · advplyr/audiobookshelf https://github.com/advplyr/audiobookshelf/issues/1953
[9] advplyr/audiobookshelf: Self-hosted audiobook and ... https://github.com/advplyr/audiobookshelf
[10] Ebooks - audiobookshelf https://www.audiobookshelf.org/guides/ebooks/
[11] Creating API Keys https://www.audiobookshelf.org/guides/api-keys/
[12] App FAQ https://www.audiobookshelf.org/faq/app/
[13] Send to E-Reader https://www.audiobookshelf.org/guides/send_to_ereader/
[14] 00jlich/abs-kosync-bridge - Docker Image https://hub.docker.com/r/00jlich/abs-kosync-bridge
[15] KOReader Pocketbook Sync https://github.com/ckilb/pocketbooksync.koplugin
[16] [Need Testers] Update for ABS <-> KOReader Sync Bridge ... https://www.reddit.com/r/audiobookshelf/comments/1q4zagh/need_testers_update_for_abs_koreader_sync_bridge/
[17] [Tester gesucht] Update für ABS <-> KOReader Sync ... https://www.reddit.com/r/koreader/comments/1q4z8w1/need_testers_update_for_abs_koreader_sync_bridge/
[18] stradichenko/audiobook.koplugin: A plugin to give TTS- ... https://github.com/stradichenko/audiobook.koplugin
[19] Audiobook plugin for KOReader [v0.1.9]! With even more ... https://www.reddit.com/r/koreader/comments/1tjyxrq/audiobook_plugin_for_koreader_v019_with_even_more/
[20] Sync ebook to ABS · Issue #49 · cporcellijr/abs-kosync-bridge https://github.com/cporcellijr/abs-kosync-bridge/issues/49
[21] Progress Sync between ABS and ThirdPartyClients like Shelfplayer · advplyr/audiobookshelf · Discussion #3538 https://github.com/advplyr/audiobookshelf/discussions/3538
[22] Update:API route for getting playback session and getting media ... https://git.laurivan.com/Mirrors/audiobookshelf/commit/bf928692d5b43ebbe147606b33c41445089e7e81?files=server%2Frouters
[23] GitHub - flip-rossi/readeck.koplugin: An unofficial KOReader plugin to add integration with your Readeck instance. https://github.com/flip-rossi/readeck.koplugin
[24] DEVELOPING YOUR FIRST PLUGIN FOR KOREADER https://kindlemodshelf.me/koreaderplugindev
[25] KOPlugin.md https://gist.github.com/consoleaf/abbe8449377f1f6ef47b86d6c0d8873d
[26] Module luasettings https://koreader.rocks/doc/modules/luasettings.html
[27] Audiobookshelf API Reference https://api.audiobookshelf.org
