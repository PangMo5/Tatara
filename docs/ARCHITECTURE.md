# Architecture

Tatara separates review state from forge APIs and terminal rendering:

```text
TataraTUI ──▶ TataraGitHub ──▶ TataraSystem ──▶ TataraKit ──▶ TataraCore
TermLoom         gh          Subprocess          TCA        Swift values
                             difftastic
    └────▶ TataraPersistence ───────────────────▶ TataraKit
               SQLiteData
```

The executable creates live clients and injects them into the store. The core
contains no UI or TCA import. Current TCA dependencies link Apple frameworks;
Linux and Windows are future ports, not currently supported build targets.

`ForgeClient` is a closure-based dependency client rather than a hierarchy of
speculative protocols. Each new forge supplies its own adapter and capability
set. GitHub draft, mergeability, branch, check-run and review states remain in
typed GitHub metadata; a GitLab adapter should add GitLab metadata and retain
the term “merge request.” Unsupported operations must remain explicit.

## Read pipeline

1. `gh api` loads paged PR/issue lists. The issue endpoint also returns PRs;
   filtering happens after pagination metadata is computed.
2. Detail acquisition obtains immutable base/head commits and their merge base,
   all changed files, conversation, review comments, check runs and statuses.
3. A file selection acquires its two immutable snapshots. A folder or `/` selection
   prepares the changed descendants as a combined diff with per-file identity.
   Renames use the old path at merge base; additions/deletions use an empty opposite side.
4. `difft --display json --strip-cr off` supplies aligned source rows and changed
   token byte ranges. Tatara validates those ranges against the exact snapshots,
   preserves zero-based-to-one-based source mapping, and retains the `highlight`
   category on each changed token. Removed/added tokens use the terminal's ANSI
   red/green, bright on dark themes and normal on Latte. Keywords, types and
   delimiters are bold; comments are italic. Changed gutters are bold directional
   colors and unchanged gutters dim the terminal foreground. Search and selection
   remain independent interaction overlays. Unknown categories retain their name
   and directional color. JSON omits unchanged syntax and collapses native novel
   words into token categories, so word-specific underlines are not guessed.
   ANSI text is not reparsed into coordinates.
5. Structural results are cached by repository, immutable revisions, paths and
   engine version. Presentation width, wrap and horizontal offset have separate prepared caches; changing the
   active source side does not rerender the document. Remote filenames never
   become local filesystem paths.

Diff panes below 100 columns and diffs with a single source side use unified presentation: each changed run contains
its old rows followed by its new rows, with shared context shown once. The original
alignment remains immutable in `sourceDiff`; the presented `diff` retains exact
path, side and line identities for every row. Wrapped rows retain full immutable
source lines with separate display-column offsets; logical and physical cursor
indices are prepared separately. Search runs against each source identity once,
then maps the match onto wrapped rows. Both layouts build source lookups on
the worker. Normal cursor movement visits both sides in unified order; a visual
range stays on its original side so it remains a valid source range. Resizing
restores the viewport and cursor through source identities, never row numbers.
Comment annotations carry focus keys and source-side placement independently of review anchors;
unified projection places each comment below its old or new source row. Search
and comment text remain distinct from reviewable source.

PR selection and review are distinct screens. The selector always shows full
metadata; the review sidebar contains a short current-PR summary and a tall Files
tree. The quick picker filters loaded items on a cancellable worker, preserves
the current PR until acceptance, and owns its own query generation.

Comment actions load a fresh REST comment and GraphQL permissions/reactions.
Below 100 columns, review geometry divides the body evenly between Files above
and Content below. Geometry is independent of focus and supplies the same bounds
for rendering, pointer dispatch and viewport updates. The PR selector retains its
own screen. When the lower pane cannot contain an inline editor, its source-owned
composer uses the available body; source and draft identities remain unchanged.

Panel titles and selection counters occupy borders. Files and PR rows use the
reclaimed header row; pointer and viewport geometry share that offset. Diff tabs
occupy the top border, and an immutable per-row file-path lookup supplies the
sticky filename from the displayed document, including combined diffs and previews.
A low-contrast interaction fill marks the focused source side without changing
syntax colors or token emphasis; unified shared rows retain both source identities.

Saving an inline draft returns to Diff. Pending cards precede published discussion
at the same anchor. R opens the final review beside Files; pending comments can be
opened, edited or removed. Pending controls keep stable local identities after removal/reordering. Unsaved
edits have separate draft identities from new comments, and removing the last pending comment invalidates its presentation.
Review preview publication checks item, immutable revisions, event, body, comments
and viewport generation. Only a completed preview exposes submission controls.

Enter on a focused published comment opens a Markdown reader. Thread construction
and wrapping run on workers; replies come from the loaded detail snapshot, while
selected-comment context refreshes identity, permissions and version. The reader
cannot produce a mutation. Editing returns to the reader with unfinished text
intact; explicit preview and confirmation still gate every published write.

`--current` uses gh's checkout-aware PR resolution and validates its host/repository
URL before opening Files. The remaining PR list loads independently and retains
the selected PR even when it is absent from that page. Missing PRs fail visibly;
the application never substitutes the first listed PR. `--repo` is mutually exclusive.

Review-thread lookup is paginated and matches the root comment's node ID. The
comment editor owns its immutable item/head and preview. Confirmation consumes
the preview once; the adapter rechecks account, body/version, permissions and head
before one REST/GraphQL mutation. Failures do not trigger retries. Successful writes
refresh detail while preserving the selected file/directory and source cursor.

The Files tree uses `/` as a synthetic root, separate from repository-relative
file paths. Selecting it uses the existing combined-diff pipeline for all changed
files. Empty trees have no root. Local search keeps unrelated rows and expands
only the ancestors needed to reveal its cursor; cancellation restores prior folds.

File status badges and insertion/deletion totals come from `ChangedFile` metadata,
not from counting difftastic's changed tokens. Zero line-count values are hidden. File comment counts include all published
comments with that exact path, including replies, file-level and outdated anchors,
and exclude PR-level discussion and local drafts. Counts are indexed when the
immutable detail is constructed, including after cache decoding. Per-row lookup is indexed and tree
indentation is one column per depth, capped to preserve filename space. Diff
language and structural status come from JSON and remain distinct from forge file
status: a modified file may have no structural changes.

The PR list already contains the overview body, so it appears before the detail
requests complete. Selection starts cancellable reads immediately, with no settling
timer. Detail responses use a count/byte-bounded LRU within the current list refresh;
explicit refresh and successful review submission invalidate the relevant cache.

`TataraPersistence` implements the injected `CacheClient` using SQLiteData and
versioned migrations. It stores data under `$XDG_CACHE_HOME/tatara/cache.sqlite`
(default `~/.cache/tatara/cache.sqlite`), scoped by forge, host and the account ID
returned by `gh api user`. Metadata has a 30-second lifetime. Immutable snapshots
and rendered diffs have no time-based expiration; diff keys include the engine
version. Explicit refresh bypasses metadata, and write validation never reads
cached heads. Payloads are bounded to 128 MiB and 256 entries, evicting the oldest
writes. No tokens or review drafts enter this cache.

The terminal viewport has explicit cell bounds. Plain text wrapping and structured
diff projection run off the main actor through `DocumentClient`. Prepared documents retain
wrapped lines, original searchable text, and per-side cursor indices; scrolling renders only the visible
window. No document-size measurement is fed back into the root layout. Search
state belongs to each pane and the help popup, with generation checks for async
content-search results. Regular-expression matches retain source and display ranges;
the worker reveals horizontally clipped matches without changing source coordinates.
Overview and discussion text concatenation also runs
off the main actor, using an immutable snapshot captured during selection.

Diff documents retain complete source and search rows, with a separate
display projection clipped to the terminal's cell width before UI layout.
This prevents a single very wide source line from entering unbounded `Text`
measurement. Wide graphemes and span styles remain intact. Prepared documents
are retained in a process-local LRU cache, limited to 24 entries and an estimated
64 MiB, keyed by immutable content identity, width and side. Cache eviction runs on its
actor, and the reducer's detail cache does not participate in UI observation.

Selection updates do not blank the previous document. A one-line pending banner
identifies the displayed PR, section, revision and file while the next preview
is being prepared. The document and its scroll position change together when
the matching generation completes. This avoids rendering an empty full pane
between two documents. Review entry is blocked while the selected preview is
pending or has failed. A presentation generation keeps old content visibly marked
as a preview even after dismissing its error; it cannot supply new review anchors
or content-search results. Stale completions cannot replace it.

Wrapping streams bounded word runs and uses TermLoom terminal-cell widths. Projection and search-index construction check
cancellation during processing. Read effects and subprocesses use utility
priority; sidebar view inputs contain small presentation rows instead of full
PR bodies or file patches. Scrollbars share clamped viewport geometry with the
keyboard scroll actions.

Focus changes highlight pane borders. TermLoom's native `TerminalApplication`
tracks the observable application and TCA state, routes input through its control
interaction map, and redraws on changes. `TerminalScreen` is a viewport-sized
snapshot of native text, borders, buttons, text fields and multiline editors.
The terminal diffs completed cell buffers before emitting output. Wheel events
route to the hovered pane without changing keyboard focus; modals receive input
before the workspace. Tatara opts into bounded scroll presentation batches: consecutive
wheel events at the same pointer position preserve ordered state changes and clamping,
while intermediate frames are omitted. Keyboard, click, resize, pointer-position and
modifier changes end the batch. Nonblocking lookahead preserves fragmented Escape
sequences. The native runtime owns raw mode and terminal restoration.

Review drafts retain native editor state for cursor movement, selection and undo.
Opening a saved draft resets confirmation state, so editing never resumes on a
submit button. Confirmation text is wrapped on a worker and published only while
the item, body, inline comments, viewport generation and task still match. Submit
controls appear after the complete preview is ready. The review reducer still
validates a fresh remote head immediately before a write.

Read effects are cancellable. Replacements cancel the previous subscription
synchronously before scheduling new work, so a late-starting older task cannot
cancel a newer generation, and generation checks reject late responses. Identical
active diff reads share a producer; cancelling one consumer preserves the others,
while cancelling the final consumer tears down that producer. Parsing and disk
restoration run outside the cache actor, so they cannot monopolize cache access.
`swift-subprocess` owns process teardown, byte collection and
cancellation; a structured timeout bounds command lifetime. Missing `gh`, missing
`difft`, authentication failure, incomplete data and command errors remain visible.

## Write pipeline

Review summary and inline comments are local drafts. A separate preview shows
the destination and complete review. Submission reloads the PR head, rejects a
changed head, then passes that exact commit ID with a single GitHub review write.
An issue uses GitHub's issue-comment API and cannot be approved or request changes.
Writes do not automatically retry because a lost response may follow a successful
remote write. Check GitHub before retrying an uncertain submission.

Inline comments use file/LEFT-or-RIGHT/source-line anchors from the structured
alignment, validated against hunk indices built with each immutable GitHub patch. Shift-V ranges must stay within
one reviewable hunk. Preview includes `start_line`/`start_side` through the end
line and side. Submission rechecks both the head and merge base when available.
Missing or truncated patches do not produce invented line mappings.

## File navigation and filters

File trees are built from metadata before presentation, with distinct directory
and file identities (including file-to-directory transitions). Collapse state is
per workspace; search preserves the complete tree and reveals matching rows. The cursor can
select a directory to prepare a combined diff for its changed descendants. Each
source row retains its file path, side, and source line; annotations have no review
anchor. Current remote comments follow their source row, while outdated or
unrepresented comments remain identified under the file header. Draft insertion
preserves the cursor and viewport by source identity. The review editor expands
beneath its source row and keeps the workspace visible. `files_view` selects tree or
flat presentation. Sidebar projections are rebuilt only when their source,
collapse state, or layout changes; navigation and view evaluation reuse them.

`/` in PRs and Files incrementally searches loaded metadata on a worker. Stable
row identities and indexed results preserve the complete list. Input moves a
transient cursor without loading previews; Enter commits, Esc restores the prior
query/cursor/folds, and n/N wrap from the current row. Search generations reject
obsolete source snapshots. `f` opens a TCA filter feature with repository labels and saved presets. Remote queries use GitHub's issue/PR search API
through `gh`; responses must still match the configured forge, repository and
kind. Saved presets live in a separate SQLiteData database under XDG data storage,
so cache eviction cannot remove them. Preset loading is owned by the parent
state transition, not a transient popup lifecycle hook. Request generations prevent
an older read from clearing an in-flight save or replacing its result.

`g/` opens a separate TCA result list and reads immutable changed-file contents
through the forge client:
head content for present files and merge-base content for deleted files. Four
bounded worker tasks evaluate ICU regular expressions, rejecting files over
32 MiB with a visible error and skipping binary or non-UTF-8 contents. Search
generations prevent obsolete responses from replacing results. Each hit retains
path, source side, line and a bounded excerpt; at most 10,000 matching lines are
retained. Opening a hit validates the current item/revisions and requests its exact
source context from difftastic alignment, including unchanged files or omitted
context. Cache identity includes the reveal location, so ordinary hunk rendering
and expanded search context cannot collide. Diff search uses
the same pattern syntax and limits results to 100,000 occurrences with a visible
error. This is content search with explicit limits, not complete ripgrep syntax
or Vim pattern compatibility.

## Deliberate initial boundaries

- Open items in one repository per process; repositories can be selected from any
  directory with `--repo`.
- Drafts and viewed marks live for this process. Draft persistence, resumable sessions,
  and multi-repository inboxes remain future work. Published-thread resolution
  and reopening are implemented through fresh GitHub permissions and a write preview.
- Diff cursor motion and visual selection are line-based. Characterwise visual
  selection and hunk-level review marks are not implemented. Review editors support
  native character editing, Unicode paste and undo/redo.
- GitHub caps its changed-file endpoint at 3,000 files. Tatara checks the reported
  count and reports incompleteness instead of showing a falsely complete review.
- TermLoom is a local source package under `ThirdParty/TermLoom`, with its immutable
  upstream revision recorded in `upstream.json` and the original MIT license retained.
  Its native application runtime owns input, focus routing, observation-driven
  redraw and terminal restoration. The local manifest exposes core and TextArea
  from the same source snapshot. Wheel-axis and scroll-presentation changes are
  committed source, exercised by unit and PTY tests; builds never patch caches.
  Upgrades must reevaluate both changes against the recorded upstream revision.
