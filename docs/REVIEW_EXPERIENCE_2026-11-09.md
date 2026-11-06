# Review workspace refinements — November 9, 2026

The focused source row uses a subtle Catppuccin background on its active side,
with stronger visual-selection and search highlights retaining priority. Source
colors and emphasis remain owned by difftastic. Shared unified rows retain the
tint when either source identity is focused. Ordinary surfaces inherit the
terminal background.

Pane titles/counts and selection positions are embedded in borders. PR and Files
rows reclaim the former title row. Diff tabs and the displayed revision occupy
the top border; filenames stay below it while scrolling. The path comes from an
immutable document lookup, so combined diffs and identified previews cannot show
another selection's filename. Pointer/header offsets follow the same geometry.

In Diff, c starts a source-anchored draft, including V ranges. Saving returns to
source with a Pending review card and R count. Pending cards precede lengthy
published conversations. R opens review completion beside Files, with draft
navigation, editing and removal. Pending controls use stable local identities rather than array positions.
Unsaved edits are separate from new-comment drafts; removing the last comment also removes its card. Drafts remain local to
the current process until explicit submission or quitting.

A focused published comment opens a reader on Enter. Markdown, thread grouping
and wrapping run on workers. Reply/edit actions use fresh selected-comment
context, and returning to the reader preserves unfinished text. The reader has
no mutation value; published actions retain their concrete previews and remote
permission/version/account/head checks. The thread uses the loaded PR replies,
with the selected comment refreshed independently.

`tatara --current` opens the checkout's branch PR directly into Files. gh owns
checkout/fork resolution; the adapter validates the returned PR identity. Other
PRs load separately, preserving the current target even outside the first page.
A missing PR is an explicit failure. This mode cannot be combined with --repo.

## Verification

- 152 Release Swift Testing tests passed, including all four palettes, unified
  shared-row tinting, sticky combined paths, draft save/edit/cancel/removal,
  reader/reply transitions, startup-list races and repository/host validation.
- The dedicated PTY scenario opens --demo --current, reads a conversation,
  preserves an unfinished reply, saves and edits a pending comment, resizes the
  sticky header and opens the final review preview. It performs no forge writes.
- The build script validates the macOS 15.0 deployment target, SDK 27.2 and local
  signing/runtime arrangement. Formatting, localization, notices and REUSE are
  checked before installation.

Raw UI captures: `.artifacts/swift-pty/review-experience/`.


## Release PTY responsiveness

The navigation probe used 320 × 64 cells, 100 fixture PRs, 120 files, an
approximately 2.5 MB overview and eight 21,000-character source lines, with
`--wide-lines --burst --dense-navigation --loading-burst --directional-burst
--animated`. Fixture storage was fresh, with the probe's initial PR/file warm-ups
before in-flight samples. Replacement preparation and cache reuse remained active.
No compiler, CPU sampler or preview recorder ran alongside these timing samples;
unrelated host workload was uncontrolled. This is a single observation run,
not a before/after speed comparison or real-network latency measurement.

Synchronous Store.send work was recorded separately for 588 inputs: p95/max
0.75/2.08 ms. The run contains 120 completed-frame observations. PR/file
in-flight selection feedback p95 was 2.95/12.85 ms, with maxima of
3.04/13.32 ms. The final tails of the 64-input directional bursts were
7.44 ms for PRs and 4.03 ms for files; these are individual tails,
not percentile estimates. Initial PR/file readiness was
2071/4178 ms, including deliberately delayed synthetic providers.

Feedback ends at synchronized terminal-cell frames and includes emulator parsing;
it does not isolate terminal-write CPU or compositor paint. Selection feedback
is independent of replacement-document readiness.

The separate loaded-list search probe passed for cancellation, complete lists,
provider isolation, resize and wrapping n/N. Query-echo p95 was
2.61/7.86 ms for PRs/Files, and file n/N p95 was
4.76 ms. Regression PTYs also passed for search/review, tree/list borders,
presets, multiline Unicode/ASCII/no-color previews, pointer/scrollbar navigation,
cross-process cache reuse, motion suppression and stopping redraws while idle.

Raw evidence: `.artifacts/swift-pty/navigation-review-ux/`,
`.artifacts/swift-pty/list-search/`, and the corresponding review/feature captures.
Executable SHA-256: `5ed97dd38f380b75f8e35bd3926d26b2aaf6a0c638a07d5fa5b04fd9cf7ffa3e`.


## Draft PR entry correction

Open draft PRs support comment composition and review completion. Draft readiness
is not a blanket client-side review prohibition: frontend entry and the adapter
no longer reject isDraft. Submission still validates the open PR, immutable head,
merge base and concrete preview, and sends the selected event through the
[GitHub review endpoint](https://docs.github.com/en/rest/pulls/reviews#create-a-review-for-a-pull-request).
Closed PRs remain blocked; provider errors remain visible and writes are not
retried automatically.

Ineligible entry states now show a localized footer hint instead of silently
ignoring c/R. A loading hint does not set the document error or cancel preparation,
and clears when the document completes. Folder entry tells the user to select a
file and open Diff. Source-coordinate and forge-patch checks remain unchanged.

156 Release tests cover draft inline/summary entry, nonfatal loading/folder hints,
exact COMMENT payloads for both ready and draft PRs, and closed-PR write rejection.
The dedicated --draft-review PTY uses a draft-marked forge fixture and exercises
folder feedback, inline composition, pending comments and the final preview.
It performs no forge writes. Raw evidence is under
`.artifacts/swift-pty/draft-review/`.
