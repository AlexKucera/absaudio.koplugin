   #32  A — audio math (AFK/Mac)
    │
    ▼
   #33  B — backend skeleton, FFI mocked (AFK/Mac)
    │
    ▼
   #34  C — first audible playback (tracer bullet, device)   ← "does sound come out?"
    │
    ▼
   #35  D — real transport + seek + position (device)         ← real position exists from here on
    ├─────────────┬───────────────┐
    ▼             ▼               ▼
   #36  E —    #37  F —           #8  sleep timer / completion / delete / diagnostics / folder picker / ebook
    speed      multi-file +       ├─ audio-INDEPENDENT ──► UNBLOCKED NOW (diagnostics, folder picker, ebook polish)
    (atempo)   chapters           └─ audio-DEPENDENT   ──► blocked by #35 (D): sleep-timer pause, completion push
    │
    ▼
   #38  G — live ABS sync (device+server)   ← needs D's position AND E's speed-correct position
        │
        ▼
        #9  sync / conflict / offline
        ├─ conflict-resolution pure logic ──► UNBLOCKED NOW
        └─ live push/pull                ──► blocked by #38 (G): live sync, offline matrix