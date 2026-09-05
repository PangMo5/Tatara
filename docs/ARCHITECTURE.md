# Architecture

Tatara separates review state from forge APIs and terminal rendering:

```text
TataraTUI ──▶ TataraGitHub ──▶ TataraSystem ──▶ TataraKit ──▶ TataraCore
SwiftTUI         gh          Subprocess          TCA        Swift values
                             difftastic
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
4. `difft` compares those snapshots. Width controls side-by-side versus inline
   presentation. Its SGR colors become styled SwiftTUI text, mapped to the active Catppuccin flavor.
   Terminal commands, OSC clipboard sequences and cursor controls are discarded.
5. Caches are bounded by bytes/entries and keyed by repository, immutable revision,
   path, width and theme. Remote filenames never become filesystem paths.

Read effects are cancellable. Generation checks cover responses that race with
cancellation. `swift-subprocess` owns process teardown, byte collection and
cancellation; a structured timeout bounds command lifetime. Missing `gh`, missing
`difft`, authentication failure, incomplete data and command errors remain visible.

## Write pipeline

Review summary and inline comments are local drafts. A separate preview shows
the destination and complete review. Submission reloads the PR head, rejects a
changed head, then passes that exact commit ID with a single GitHub review write.
An issue uses GitHub's issue-comment API and cannot be approved or request changes.
Writes do not automatically retry because a lost response may follow a successful
remote write. Check GitHub before retrying an uncertain submission.

Inline comments use file/LEFT-or-RIGHT/source-line anchors validated against the
GitHub patch. Difftastic's visual line positions are not API anchors. Missing or
truncated patches do not produce invented line mappings.

## Deliberate initial boundaries

- Open items in one repository per process; repositories can be selected from any
  directory with `--repo`.
- Drafts and viewed marks live for this process. Persistence, resumable sessions,
  review-thread resolution and multi-repository inboxes remain future work.
- Inline comments use an explicit source line and side; visual range selection,
  hunk-level review marks and continuous multi-file diffs remain future work.
- GitHub caps its changed-file endpoint at 3,000 files. Tatara checks the reported
  count and reports incompleteness instead of showing a falsely complete review.
- SwiftTUI is pinned within one pre-1.0 minor series and the lockfile is committed.
