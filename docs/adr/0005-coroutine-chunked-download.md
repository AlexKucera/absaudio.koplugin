# Background download via coroutine + chunked reads

Status: accepted

Downloads use Lua coroutines with small (~8-16KB) chunked HTTP reads, yielding to KOReader's event loop after each chunk to update a progress bar widget. This deviates from the upstream plugin's synchronous blocking download pattern.

Rationale: audiobook files are 100MB–500MB+. A blocking download would freeze KOReader's UI for 5–20 minutes. Coroutines are the proven KOReader pattern for long-running operations (used by NewsDownloader, Calibre plugins, etc.). Each chunk read blocks for only milliseconds — imperceptible to the user. This approach also enables cancel buttons, resume-on-disconnect (via HTTP Range), and progress reporting without additional infrastructure.
