# Architecture

Tatara separates review state from forge APIs and terminal rendering:

```text
TataraTUI ──▶ TataraGitHub ──▶ TataraSystem ──▶ TataraKit ──▶ TataraCore
SwiftTUI         gh          Subprocess          TCA        Swift values
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
3. Only the selected file's two snapshots are acquired. Renames use the old path
   at merge base; additions/deletions use an empty opposite side.
4. `difft --display json --strip-cr off` supplies aligned source rows and changed
   token byte ranges. Tatara validates those ranges against the exact snapshots,
   preserves zero-based-to-one-based source mapping, and renders changed tokens
   with semantic Catppuccin colors. ANSI text is not reparsed into coordinates.
5. Structural results are cached by repository, immutable revisions, paths and
   engine version. Presentation width and selected side have separate prepared
   caches. Remote filenames never become local filesystem paths.

The PR list already contains the overview body, so it appears before the detail
requests complete. Repeated selection keys coalesce for 120 ms before starting
network work. Detail responses are reused within the current list refresh;
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
wrapped lines and a normalized search index; scrolling renders only the visible
window. No document-size measurement is fed back into the root layout. Search
state belongs to each pane and the help popup, with generation checks for async
content-search results. Overview and discussion text concatenation also runs
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
pending, and stale completions cannot replace the identified preview.

Wrapping streams bounded word runs instead of giving a whole PR body to the
shared glyph-width cache. Projection and search-index construction check
cancellation during processing. Read effects and subprocesses use utility
priority; sidebar view inputs contain small presentation rows instead of full
PR bodies or file patches. Scrollbars share clamped viewport geometry with the
keyboard scroll actions.

Focus changes highlight pane borders. Each pane and the status bar observe their
own state, so a response does not rebuild the entire workspace. `DocumentViewport`
is an Equatable value view containing only visible lines and highlights. Projection
reuses measured widths instead of repeatedly entering the shared text-layout cache.
Wheel events route to the hovered pane
without changing keyboard focus, and the reducer blocks underlying panes while
help or a review editor is presented.

Read effects are cancellable. Replacements cancel the previous subscription
synchronously before scheduling new work, so a late-starting older task cannot
cancel a newer generation. Selection delays re-enter the reducer before starting
network work, and generation checks reject late responses.
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
alignment, validated against the GitHub patch. Shift-V ranges must stay within
one reviewable hunk. Preview includes `start_line`/`start_side` through the end
line and side. Submission rechecks both the head and merge base when available.
Missing or truncated patches do not produce invented line mappings.

## File navigation and filters

File trees are built from metadata before presentation, with distinct directory
and file identities (including file-to-directory transitions). Collapse state is
per workspace; search exposes matching files with their ancestors. The cursor can
select a directory without starting a diff request. `files_view` selects tree or
flat presentation.

`f` opens a TCA filter feature. Remote queries use GitHub's issue/PR search API
through `gh`; responses must still match the configured forge, repository and
kind. Saved presets live in a separate SQLiteData database under XDG data storage,
so cache eviction cannot remove them. Preset loading is owned by the parent
state transition, not a transient popup lifecycle hook.

## Deliberate initial boundaries

- Open items in one repository per process; repositories can be selected from any
  directory with `--repo`.
- Drafts and viewed marks live for this process. Draft persistence, resumable sessions,
  review-thread resolution and multi-repository inboxes remain future work.
- Cursor motion and visual selection are line-based. Characterwise editing,
  hunk-level review marks and continuous multi-file diffs remain future work.
- GitHub caps its changed-file endpoint at 3,000 files. Tatara checks the reported
  count and reports incompleteness instead of showing a falsely complete review.
- SwiftTUI is pinned within one pre-1.0 minor series and the lockfile is committed.
