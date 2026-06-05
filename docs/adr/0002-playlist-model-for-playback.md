# Playlist-based playback model

Status: accepted

All audiobooks are played as a **playlist**, even single-file M4B books (which are degenerate playlists of length 1). Multi-file books download all audio files into a single `{author}_{title}/` folder and play them sequentially via inkview's `LoadPlaylist()` / `PlayTrack(n)` APIs. If playlist APIs don't work from KOReader context (blocked on hardware testing), we fall back to single-file `PlayFile()`.

This decision means `player.lua`, the manifest, sync math, chapter navigation, and sleep timer all operate on a "book = ordered list of files" model from day one. Retrofitting single-file→playlist later would touch every one of those modules.
