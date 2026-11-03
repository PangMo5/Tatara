<!-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors -->

> Historical investigation. Commands, dependencies and UI descriptions reflect the
> date of this report. See the [README](../README.md) and [architecture](ARCHITECTURE.md)
> for the current supported behavior.

<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Review workspace verification — 2026-09-15

The application now starts with a detailed PR selector. Enter opens a review
workspace with a compact current-PR summary above a tall Files tree. Ctrl-p opens
a local picker for loaded PR titles, numbers and authors. This replaces the old
compact/rich density setting.

Diffs wrap by default. Source-line identity remains independent of display rows;
j/k move source lines and gj/gk move display lines. With wrapping disabled,
zh/zl, zH/zL, z0 and horizontal wheel input move the source viewport. Ctrl-f/Ctrl-b
page content with a two-line overlap and move its cursor even while Files keeps
focus. Manual reflow refreshes search highlights without selecting another match.

Published comments have independent focus keys. gc toggles comment/source focus,
and braces move between comments. Reply, own-comment editing/deletion, all eight
reaction types, thread resolution/reopening, copying and permalinks are supported.
Comments occupy their source side in split diffs and retain side labels when
unified. A search match on a comment also selects that comment as the action target.

Prose rendering includes headings, Setext headings, code fences, emphasis,
strikethrough, nested quotes, task lists, tables, reference links and image alt
text/destinations. Narrow tables become labeled records instead of losing cells.
This is text rendering: images and arbitrary HTML are not executed or embedded.
Immutable diff source is never interpreted as Markdown.

## Correctness gates

- 124 Swift tests passed, with no skipped tests.
- Universal macOS Release build passed; the default Debug test scheme remained Tatara.
- Format, 182 strings across five locales, 24 package notices and REUSE checks passed.
- Release PTY checks passed for PR selection, burst picker acceptance, Files layout,
  wrap/horizontal scrolling, paging, comment focus and all action previews.
- Regression tests cover Unicode/tab wrapping, complete-source search across wraps,
  original review coordinates, manual-scroll search preservation and comment targeting.
- Mock GitHub tests cover endpoint selection, head/body/account/ownership/permission
  changes, preview consumption and a single failed write without retry.
- Authenticated GitHub schema introspection confirmed the permission, reaction and
  review-thread fields used by the adapter. No live comment mutations were performed.

Comment writes re-read the target and its GitHub permissions, compare the preview's
body/version/account, and validate the PR head before issuing one mutation. Closing
a form never writes. GitHub can still change between the last read and a request;
these comment APIs do not provide an atomic multi-resource conditional write.

## Release PTY measurements

Measurements observe completed synchronized terminal frames, with no CPU sampling
or preview recording and no concurrent builds. These are local fixtures, not live
GitHub/network latency claims. Terminal size: 176 × 48.

The navigation fixture has a roughly 2.4 MB overview and eight roughly 21,000-column
source lines per file. Wrapping is enabled. Two files are warmed before repeated
selection tests. Its fake difft process deliberately waits four seconds; the
4.13-second first-file readiness measurement therefore includes that injected wait.
PR warmup readiness was 2.13 seconds for the oversized prose fixture.

| Sequence | Median | p95 | Maximum |
| --- | ---: | ---: | ---: |
| Warm PR selection | 2.01 ms | 2.73 ms | 2.73 ms |
| Warm file selection | 2.22 ms | 2.68 ms | 2.68 ms |
| File selection during work | 8.78 ms | 10.22 ms | 33.15 ms |
| Diff source cursor | 3.31 ms | 6.40 ms | 6.40 ms |
| 48,000-match long-line search | 124.22 ms | 126.42 ms | 126.42 ms |
| Warm quick picker to Ready (20 samples) | 10.27 ms | 11.17 ms | 11.17 ms |

Synchronous Store.send across the navigation trace: median 0.288 ms, p95 1.250 ms, maximum 8.481 ms.
The quick-picker measurement sends Ctrl-p, the PR number and Enter in one burst
and waits for the accepted PR's complete Ready frame; it excludes four warmup
switches. PR/file alternating bursts used 25 ms and 120 ms input cadence. The
worst final-help-frame response after these bursts was 9.71 ms.

## Local evidence

- `.artifacts/workspace-redesign-final-tests.json`
- `.artifacts/workspace-redesign-release-build.json`
- `.artifacts/swift-pty/reading-workspace/` (screens and terminal captures)
- `.artifacts/swift-pty/navigation-reading-layout-final/navigation.json`
- `.artifacts/swift-pty/navigation-reading-layout-final/input.tsv`
- `.artifacts/swift-pty/picker-benchmark/latency.json`

Verified Release SHA-256: `7fc8d059a871f13521b1b876278483f0d71559a016148a87dd80712d45a9036f`.

The adapter follows GitHub's [review-comment API](https://docs.github.com/en/rest/pulls/comments),
[issue-comment API](https://docs.github.com/en/rest/issues/comments),
[review-thread schema](https://docs.github.com/en/graphql/reference/pulls), and
[reaction schema](https://docs.github.com/en/graphql/reference/reactions).

## Picker Vim follow-up

The picker now opens in Normal mode. Configured j/k and gg/G bindings navigate
the list; Ctrl-d/u and Ctrl-f/b move by half/full visible pages. Slash or i enters
Insert mode, where ordinary letters remain query text. Escape leaves Insert mode
or cancels a pending motion before closing the picker. The modal owns its input
even when the underlying Diff has a Visual selection. Dialog generations are
monotonic, so a closed picker's late results cannot replace a reopened picker.

126 tests and the Release PTY mode/navigation checks passed. The updated warm
picker benchmark sends Ctrl-p, slash, number and Enter in one burst: 20 samples,
median 12.21 ms, p95 12.74 ms, maximum 12.74 ms.
This remains a synthetic warm-cache measurement.

Follow-up Release SHA-256: `d0546c2076aba01ad5b9f878724b0bb28fb12c7bc1df8ac5caf1710d9041b306`. Evidence:
`.artifacts/picker-vim-tests.json`, `.artifacts/picker-vim-release-pty.log`,
and `.artifacts/picker-vim-benchmark.log`.
