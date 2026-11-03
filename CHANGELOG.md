# Changelog

Version headings identify source versions, not published releases. No binary release has been published.

## 0.1.0

- Browse GitHub pull requests and issues through `gh`, including Enterprise hosts.
- Review immutable merge-base/head file snapshots with difftastic inside TermLoom.
- Read conversation, inline discussion, check runs and submitted review states.
- Compose review summaries and source-anchored inline comments with an explicit submission preview.
- Navigate with Vim motions and configurable keys; mark files reviewed for the current revision.
- Keep long overviews inside a fixed viewport, search each pane, and filter commands in a help popup.
- Preserve committed search status and clear it with Escape; use Ctrl-f/Ctrl-b to page the main pane from a sidebar.
- Show interactive pane scrollbars and cooperatively cancel large document processing and obsolete subprocesses.
- Scroll the hovered pane with a mouse wheel or trackpad while retaining keyboard focus.
- Isolate pane observation and reuse unchanged document viewports; record reproducible PTY latency and frame profiles.
- Keep an identified preview while another selection loads, bound wide diff rows before layout, and cache prepared documents.
- Navigate configurable file trees, identify focus with pane borders, and save GitHub search presets.
- Use difftastic source alignment for a line cursor and Shift-V range comments on either side, with head and merge-base validation.
- Reuse account-scoped metadata, immutable snapshots and diffs across launches with a bounded SQLiteData cache.
- Run development, release automation and PTY checks entirely through Swift tools.
- Use Catppuccin Latte, Frappé, Macchiato and Mocha in five languages.
- Prepare signed, notarized macOS arm64/x86_64 archives for GitHub Releases; distribution remains unverified.
