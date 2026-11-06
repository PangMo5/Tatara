# List search and file-content results — November 9, 2026

Slash search in PRs now finds loaded titles, numbers, authors and branches. In
Files it finds names and repository-relative paths, including collapsed rows.
Both preserve unrelated rows. An incremental query highlights matches and moves
a transient cursor without changing the selected PR/file or preparing its preview.
Enter confirms; Escape during input restores the original query, cursor, scroll
and directory folds. Confirmed n/N motions wrap from the current cursor, including
after ordinary navigation. Escape after confirmation clears the query. GitHub
queries and saved presets remain under f, independently of local list search.

Search runs on workers with cancellation and source generations. Results retain
stable IDs, ordered match rows and immutable highlight/index tables. Publication
cannot move a cancelled search or consume row indices from another source. File
and item searches retain separate result/error ownership. A missing match leaves
the complete list visible; an invalid expression remains a visible prompt error.

The g/ result list searches immutable changed-file contents: head for present
files and merge base for deleted files. It executes on Enter with at most four
concurrent provider reads. Binary/non-UTF-8 contents have no searchable text;
files over 32 MiB and queries over 10,000 matching lines fail visibly. Each result
retains an exact path/side/line and a bounded highlighted excerpt. The result
window sits above the footer and adapts to its results and viewport. j/k clamp at
the ends, n/N wrap, / or i edits, and Escape leaves input before closing.

Opening a content result verifies item and immutable revision ownership. The diff
request includes the source location, and difftastic alignment reveals that
location's context even when normal hunk context omits it. Structurally unchanged
files can show equal source context. Ordinary and revealed diff cache identities
include their different options. Search navigation never fabricates review
anchors; inline writes still require the forge patch and fresh remote checks.

The interaction follows Neovim's [incremental search](https://github.com/neovim/neovim/blob/master/runtime/doc/options.txt)
and [quickfix](https://github.com/neovim/neovim/blob/master/runtime/doc/quickfix.txt)
conventions. Tatara keeps its existing case-sensitive ICU regular expressions;
`(?i)` enables insensitive matching.

## Verification

144 Swift Testing tests passed, including complete tree/list projections,
transient preview preservation, cancellation and stale-result rejection,
remote qualifier submission through f, hidden-path navigation, source-side jumps,
revision rejection, invalid patterns and omitted/unchanged source context.

The Release PTY results below distinguish synchronous input from completed
terminal-frame feedback. These are local fixture observations, not a real GitHub
latency claim or a before/after speed comparison.

The sequence used 100 loaded PRs, 120 files, a 320 × 64 viewport and a resize to
240 × 48. Fixture storage was fresh; the initial PR and first diff were prepared
before query input. The file fixture contains 25,000 repeated source lines plus a path header. Matched-file
navigation then uses normal provider preparation, cancellation and caches.
No compiler, CPU sampler or preview recorder ran alongside timing samples;
unrelated host workload was uncontrolled. Screenshots are outside input samples.

| Completed-frame feedback | Samples | p95 (ms) | Maximum (ms) |
| --- | --- | --- | --- |
| PR query input echo | 12 | 2.10 | 2.10 |
| Files query input echo | 23 | 3.32 | 3.46 |
| Files n/N selection | 48 | 3.22 | 10.01 |

Query echo is separate from complete matching-result publication. From the last
query key to the frame with the expected cursor and complete match count, the
single observed PR/Files tails were 6.97/7.05 ms. These two tails are single
observations, not percentile estimates. The provider request log did not change
while typing either query.

Synchronous Store.send work was recorded separately for 91 keyboard inputs:
p95/max 0.28/1.22 ms. Opening the first file and reaching Ready took
4965.32 ms, including input, provider/preparation work and terminal output.
The first matched file was ready before repeated n/N navigation. The final
selection-to-Ready tail after that burst was 21.63 ms; that final file had
already been prepared, while superseded reads/preparation may be cancelled.
Selection feedback does not wait for replacement documents. Captures end at
synchronized terminal-cell frames, including emulator parsing; they do not isolate
terminal-write CPU or compositor paint.

Release PTY checks also passed for result excerpts and exact-line jumps, narrow
result windows, four palettes, existing comments and inline review resizing.
Workspace checks passed for pointer/scrollbar navigation and cross-process cache
reuse. Separate checks passed for tree/list configuration, persistent presets,
loading cancellation, motion suppression, ASCII output and zero idle redraws. All flows use fixtures and perform no forge writes.

Raw evidence: `.artifacts/swift-pty/list-search/`,
`.artifacts/swift-pty/search-review/`, and `.artifacts/swift-pty/workspace/`.
Release executable SHA-256: `e03dafa9f11cada2e0510839de4aa6d5f56fb87b2a662e3fbee1ed4c43c13294`.
