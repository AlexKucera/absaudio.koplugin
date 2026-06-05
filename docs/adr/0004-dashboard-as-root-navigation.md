# Dashboard as root view, not library browser

Status: accepted

The plugin opens to a **dashboard** with four sections (resume last book, downloaded books, browse library, settings). Library browsing is an explicit navigation action from the dashboard, not the default root view.

This deviates from the upstream plugin (naleo/audiobookshelf.koplugin), which uses the library browser as its root screen. The reason: this plugin's primary value is **local playback + sync**, not browsing a remote catalog. The user spends most of their time with already-downloaded content. The dashboard puts downloaded/resumable content front and center and relegates library browsing to a deliberate action.
