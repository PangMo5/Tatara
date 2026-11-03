# Search, inline review, and color audit — 2026-09-10

> Historical investigation. Commands, dependencies and UI descriptions reflect the
> date of this report. See the [README](../README.md) and [architecture](ARCHITECTURE.md)
> for the current supported behavior.


## Result

PR search now submits GitHub query syntax. The filter popup includes repository
labels, including quoted names with spaces. Files search matches immutable file
contents, and focusing a folder presents its changed descendants together. Diff
search highlights individual regex occurrences and moves the source cursor with
`n`/`N`, revealing horizontally clipped matches. Line comments and review previews
expand below the selected source while the workspace remains visible.

Keyboard pane focus changes only through Tab and Shift-Tab. Tree h/l operates on
the tree; Diff h/l selects its source side. Numeric pane shortcuts were removed.

## Search and review contracts

- Item queries execute on Enter through the existing `gh` adapter. Host,
  repository, kind, completeness, and GitHub's 1,000-result limit remain validated.
- File queries inspect head content, or merge-base content for deleted files.
  Four worker tasks bound concurrent reads. Each file has a visible 32 MiB limit;
  binary and non-UTF-8 contents are skipped. Matching files retain their ancestors.
- Patterns use Foundation's ICU regular expressions, case-sensitive by default;
  `(?i)` enables case-insensitive matching. This provides grep-style content
  searching and Vim-style navigation, not exact ripgrep or Vim pattern syntax.
- Diff search excludes generated line numbers. UTF-16 source ranges are mapped
  through sanitization, tab expansion, and horizontal clipping. A 100,000-match
  ceiling produces an error. Obsolete query generations cannot publish results.
- Combined diff rows carry path, side, and source line. A visual range must remain
  in one file and one valid forge patch hunk. Annotation rows are never anchors.
- Current remote comments follow matching source rows. Outdated, file-level, or
  unrepresented comments appear under the corresponding file header. The app
  does not infer an updated line for an outdated comment.
- Pending drafts are displayed only for their exact head and merge base. Adding
  a draft preserves cursor and viewport positions by source identity. Review
  entry, addition, preview, and submission retain revision ownership checks.
- Summary editing and Preview remain inside the expanded Diff panel. Existing
  general review/comment entry outside Diff retains the full editor. Submission
  still requires the concrete preview; the validation runs made no forge writes.

## Color inventory

The audit covered every color use in `Palette`, `WorkspacePresentation`,
`EditorPresentation`, `TerminalScreen`, and the difftastic span adapter. Palette
1.8.0 supplied the 26 named colors and 16 ANSI colors for each flavor. Guidance
came from the official [Catppuccin style guide](https://github.com/catppuccin/catppuccin/blob/main/docs/style-guide.md)
and [palette data](https://github.com/catppuccin/palette/blob/main/palette.json).

| Rendered role | Current implementation |
| --- | --- |
| Main content / sidebars and bars | Base / Mantle |
| Editors | Surface0, Text |
| Body and titles / secondary copy | Text / Subtext0 |
| Active / inactive borders | Lavender / Overlay0 |
| Active tabs and controls | Lavender; focused button text uses Base |
| Selection | Overlay2 at 25%, blended against the actual surface |
| Search / current match | Teal at 25% / Red at 30%, with Text foreground |
| Added / removed source | Green / Red foreground, with the ordinary Base background |
| Paths / hunk headers / diff headers | Pink / Peach / Blue |
| Diff metadata / review annotations | Overlay2 / Teal |
| Folder paths and review addresses | Blue |
| Reviewed files | Green |
| Progress / errors | Yellow / Red |
| Application cursor markers | Rosewater |
| Scrollbar thumb / track | Overlay2 / Overlay0 |
| ANSI 0–15 | Full official per-flavor table; bright colors stay distinct |
| Extended ANSI 16 / 17 | Peach / Rosewater |

The previous implementation used Mauve for active borders, Surface0 for inactive
borders, an opaque selection, and collapsed bright ANSI values onto regular
colors. These were corrected. Search now paints precise match spans. Theme
changes reuse prepared content. The active search background was independently
checked in PTY cells: Latte `E6ADBD`, Frappé `674B59`, Macchiato `604456`, and
Mocha `5E3F53`.

Terminal opacity is implemented by preblending RGB, because terminal cells are
opaque. The physical terminal cursor remains controlled by the host terminal.
Tatara renders difftastic's structured changed-token ranges and keyword emphasis;
the JSON interface does not carry the full unchanged-source syntax styling of its
native terminal output. Tatara does not add an independent syntax highlighter. `--no-color`
uses terminal defaults with non-color emphasis for selection and matches.

### Follow-up correction: difftastic backgrounds and Vim keys

The initial audit added 18% green/red diff background fills. User review correctly
identified these as an invented rendering layer. They have been removed from
both changed tokens and one-sided lines, including the unused palette roles.
The installed difftastic 0.70.0 (`8033439`) was run directly on a Swift fixture:
its ANSI output contains foreground colors and emphasis, with no diff background
colors. `--background` chooses light/dark contrast; it does not request painted
addition/deletion backgrounds. The receipt is
`.artifacts/vim-difftastic/native.ansi`. Search and visual-selection overlays remain.

Diff now supports `*`/`#` for whole-word searches and `g*`/`g#` for partial-word
searches. `n` preserves the originating direction and `N` reverses it; navigation
starts from the current source position after manual line movement. The existing
line cursor uses the first keyword on its line, or the current search-hit offset.
Unicode word extraction and literal regex escaping run on a cancellable worker.
Stale extraction cannot overwrite another source position or query. Repeated
match lookup uses binary search over ordered source positions.

`zt`/`zz`/`zb` adjust the viewport around the current source line without changing
the cursor, visual anchor, or pane. Document boundaries clamp the viewport.
Bindings and localized help share `Keymap`. The search command semantics follow
the [Vim search reference](https://vimhelp.org/pattern.txt.html#star); Tatara remains
a line-oriented review interface rather than a complete Vim editor.

PR and file lists now reserve two visible neighbors above and below the selected
entry whenever the list and pane have enough rows. The shared viewport arithmetic
also drives mouse hit testing and scrollbar selection, so their item identities
remain aligned with presentation. Short panes reduce the margin; list boundaries
clamp it. This computation is constant-time and does not start content work.
Frame tests cover both lists at terminal heights 16 and 40. The follow-up Debug
suite executes 83 tests, with zero failures or skips; the Release build passes.

The follow-up executable is
`726205ef7d94a988f867ca0e133bf43ee79a0323c1894607e8a91c58a0d56f90`.
Release PTY `--vim`, `--search-review`, and `--workspace` pass. The dense
directional fixture additionally verifies both preceding and following pairs
after every 8/32/64-input replay, for both lists at 104 × 32 and 320 × 64.
Each pane has 104 timed selections per viewport: PR p95/max are 1.21/2.88 ms
and 2.13/4.05 ms; Files p95/max are 2.36/3.66 ms and 4.59/5.67 ms respectively.
The same synthetic-workload and completed-frame limits described below apply.
Receipts are under `.artifacts/swift-pty/navigation-vim-context-{104,320}/`.
Format, 121 localized strings in five locales, third-party notices, and REUSE pass.

## Verification

- XcodeBuildMCP: 78 tests passed, zero failed or skipped; Release build passed.
- Search tests cover remote submission timing, deleted and unchanged source
  content, cancellation/stale responses, file identities and comment placement,
  stale draft rejection, exact cursor movement, Unicode ranges, offscreen
  matches, label quoting, and keyboard pane focus.
- Frame tests exercise all four palettes, exact highlighted cells, inline editor
  position with surrounding source, and no-color highlighting.
- Release PTY `--search-review`: query, labels, file content, folder diff,
  current/outdated comments, n/N, four palettes, inline range editing, resized
  editor, inline preview, and preserved cursor all passed.
- Release PTY `--features`, `--editors`, and `--workspace` passed, including
  Unicode paste, undo/redo, mouse, scrollbars, pagination, resize, saved presets,
  and cache reuse across processes.
- SwiftFormat, 113 catalog entries across five locales, notices for 24 packages
  plus Catppuccin, REUSE, and diff whitespace checks passed.

PTY checks wait for completed synchronized frames. The new scenario initially
looked for Preview before the add-comment transition completed; the harness now
waits for the rendered control before clicking it.

## Release navigation measurements

Executable SHA-256:
`89737bc486808d46ed72b2aa339f7bb5f3018146729ac0df7291663f0a1b9eb9`.

Two sequential runs used isolated synthetic caches and a dense delayed-loading
fixture, with builds and profilers idle. Each replay sends 8, 32, or 64 downward
motions at 25 ms intervals. Each input is paired with the first completed PTY
frame reflecting that selection; each pane therefore has 104 observations.

| Viewport | Interaction | Median ms | p95 ms | Maximum ms |
| --- | --- | ---: | ---: | ---: |
| 104 × 32 | PR selection | 0.96 | 1.17 | 2.54 |
| 104 × 32 | File selection | 1.30 | 2.89 | 3.37 |
| 104 × 32 | Diff half-page, 16 samples | 1.16 | 1.39 | 1.39 |
| 320 × 64 | PR selection | 1.76 | 2.06 | 4.10 |
| 320 × 64 | File selection | 3.02 | 4.26 | 5.38 |
| 320 × 64 | Diff half-page, 16 samples | 3.41 | 3.56 | 3.56 |

These are selection/frame measurements under synthetic external work, not GitHub
network latency or final-document readiness. Reducer timing was not separately
instrumented in these runs. No old/new performance claim is made from two current
build runs. Full receipts, request counts, and frames are in
`.artifacts/swift-pty/navigation-search-review-{104,320}/navigation.json`; workflow
snapshots are under `.artifacts/swift-pty/search-review/`.
