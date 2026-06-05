# Sync conflict resolution: furthest-wins with isFinished guard

Status: accepted

When local and server positions conflict, the plugin keeps the **furthest position** (higher `current_time` wins). This handles the common cases correctly: listening ahead on either device captures that progress.

The exception: if the server reports `isFinished == true` and the local position is **earlier**, the user is prompted before overwriting ("You finished this book on another device. Overwrite progress?"). This prevents losing a completion marker when re-listening — a scenario where furthest-wins would silently do the wrong thing.

Considered alternatives: last-write-wins (simpler but loses data), timestamp-based (requires synchronized clocks across devices), manual-resolution-only (too much friction for a personal tool).
