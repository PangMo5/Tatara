# GitHub and diff preparation latency — November 9, 2026

## Reference and changes

Reviewed [tuicr](https://github.com/agavra/tuicr) at
`eaaf0187913b078a8da8d473548ba3f4b2e43af4`, especially
[`local_git.rs`](https://github.com/agavra/tuicr/blob/eaaf0187913b078a8da8d473548ba3f4b2e43af4/src/forge/local_git.rs),
[`pr_open.rs`](https://github.com/agavra/tuicr/blob/eaaf0187913b078a8da8d473548ba3f4b2e43af4/src/forge/pr_open.rs)
and the GitHub CLI adapter. Its useful patterns are local immutable-object reads,
limited metadata selection and parallel independent reads. Tatara retains its own
full selection metadata, difftastic rendering and forge-anchor validation.

- The first PR page now obtains its complete rich metadata in one GraphQL request,
  rather than a REST page followed by enrichment. Other pages and forge search
  retain native pagination/query semantics. Overflowing nested connections are
  completed from the native record with update/identity validation; partial GraphQL
  errors remain visible. CI/review state, labels, assignees, reviewers, teams,
  milestone and change/commit/comment counts are preserved.
- A matching local checkout can supply pinned commit blobs. Discovery requires a
  matching forge host/repository and Git >=2.43; promisor/partial clones are not
  selected. Blob reads use NUL-delimited `cat-file`, retain binary bytes and unusual
  paths, disable lazy fetching and never inspect the worktree copy. Missing
  objects use the forge provider; actual Git/protocol errors propagate. Account
  identity is still obtained from GitHub before account-scoped cache publication.
- Combined folder/root diffs prepare up to four files concurrently, preserve
  provider file order and source identity, and use structured cancellation. This
  removes serial per-file network/preparation waits without unbounded prefetching.
- Local discovery overlaps the existing account/setup work. The process runner
  distinguishes executable paths from PATH names.
- Diff loading uses a two-row hammer/anvil in the existing header/status area while
  retaining the identified preview. Empty content uses the larger scene. Source
  search does not paint loading chrome over current source rows. Form/comment
  loading labels share the compact indicator and motion preferences.

## Live measurements

A private active workload was measured without recording repository names, PR
numbers, paths or source in this report. Each Release PTY launch used an isolated
application data/cache directory, English UI, wrapped source, 176x40 cells and
normal animation. The same PR was selected for file-diff observations. Repository
identity was explicit in both runs; these timings exclude the default-repository
detection request. Provider data and network/server load could change between the
single sequential runs.

| Stage | Before (ms) | After (ms) |
| --- | --- | --- |
| Initial PR list | 4061 | 4446 |
| Initial overview ready | 6927 | 7327 |
| First pinned file diff | 1128 | 127 |
| Second pinned file diff | 1097 | 114 |
| Cached first-file revisit | 3 | 3 |

Initial list/overview timing did not demonstrate an improvement and remains
network-dominated. The local immutable-file path reduced the observed cold file
wait by roughly 9x; memory-cache revisits were already fast. This is one pair,
not a statistical tail-latency claim.

Separate command probes found approximately 1.0 s per raw-content API call versus
36–44 ms for corresponding local blobs, with equal byte counts. The previous
initial REST page was 953,007 bytes for 27 PRs; a one-request rich GraphQL page was
413,250 bytes for 28 PRs. This supports reduced response volume, not a controlled
same-page latency improvement. Seven existing parallel detail endpoints each took
roughly 1.2–1.4 s after a roughly 1.2 s PR request. `compare?per_page=1` did not reduce
this workload's response size and was not adopted as a claimed optimization.

A 12-second Time Profiler attachment was saved, but the app was idle and the call
tree contained no CPU samples. It is not evidence about preparation CPU hotspots.
The demonstrated improvements above concern data acquisition and bounded
parallel work, not an unmeasured Markdown/parser rewrite.

## Verification

- 136 Swift Testing tests passed: byte-preserving local reads, dirty worktree and
  unusual paths, absent/mismatched/partial repository handling, visible local
  failures, complete PR metadata, native later-page pagination, nested-connection
  overflow and update validation, bounded parallel completion and stable file order.
- Release builds retain SDK 27.2 / minimum macOS 15.0 and the signing identifier.
- Release PTY loading passed initial, diff/preview, reduced-motion, stable,
  accessibility, ASCII/no-color, resize, keyboard feedback, completion and idle stop.
- Workspace/cache reuse, source search/review/anchors and 120 animated navigation
  observations passed. The 64-key PR/file loading replay tails were 5.36/3.38 ms;
  in-flight selection p95/max were 2.17/2.39 ms (PR) and 11.20/12.77 ms (file).
  Fresh synthetic caches, eight 21,000-character source lines, 100 PRs and 120
  files were used. Synchronization is measured at completed PTY output, not
  physical display/compositor timing.
- Formatting, catalog, notices and REUSE checks passed. No forge writes occurred.

Private live diagnostics and raw timings remain in ignored `.artifacts/` paths.
