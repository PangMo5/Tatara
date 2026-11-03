<!-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors -->

> Historical investigation. Commands, dependencies and UI descriptions reflect the
> date of this report. See the [README](../README.md) and [architecture](ARCHITECTURE.md)
> for the current supported behavior.

<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Provider information and terminal presentation

## Interaction

Enter moves from a selected PR into Files, then from a file into Diff. Enter on a directory retains its fold/unfold behavior. Tab and Shift-Tab continue to cycle panes. The preferred shared PR/Files width is 52 columns, configurable with `sidebar_width` or `--sidebar-width`. The layout preserves at least 60 content columns in the split layout; terminals below 100 columns retain the single-pane layout.

`detail_level = "compact"` is the default. `i` toggles compact/rich details for the session, and `--detail-level rich` overrides the configuration. Compact rows retain one line with state, PR number, title and summary badges. Rich rows use two lines, adding author, UTC update date and labels. Selection, mouse hit testing, scrollbars and half-page movement use the corresponding item capacity. Wheel and scrollbar input move only the viewport: keyboard pane focus, selected PR/file and the Diff source cursor stay unchanged, including when their rows leave the screen. Keyboard selection/cursor motions and explicit clicks reveal their target; normal rendering never pulls a manually scrolled viewport back to the selection.

The Overview spells out review and CI states and shows comment counts, branches, file/change/commit totals and labels. Rich Overview adds assignees, requested users/teams, milestone, timestamps and immutable revision identity. Badges use semantic Catppuccin colors plus textual marks, so color is not the only signal. `CI` identifies checks, `R` review decision and `c` comment count. No badge is shown for an absent API value; Overview labels missing review/CI data as “Not reported.” Zero comments omit the list badge but remain visible as zero in Overview.

Comment bodies and descriptions use Foundation's inline Markdown parser with explicit heading, quote and fenced-code handling. Bold, emphasis, inline code, links, strikethrough and line breaks are supported. This is not a complete GitHub Markdown renderer: tables, nested layout and embedded media are not rendered as web widgets. Remote control characters are sanitized while Unicode joining characters and source code contents are preserved. Comment cards use a bounded readable width, a subtle surface and a vertical marker. Diff source colors still come from difftastic.

## GitHub field mapping

GitHub, including GitHub Enterprise, remains the only implemented forge. All requests use the existing `gh` identity and hostname. No separate HTTP or authentication path was added.

| Information | Source | Semantics |
| --- | --- | --- |
| Labels, assignees, milestone, requested users/teams | REST pull request / issue resources | Native names; reviewer requests are populated by the selected PR detail response. |
| PR review summary | GraphQL `reviewDecision` | Typed `APPROVED`, `CHANGES_REQUESTED`, `REVIEW_REQUIRED`, or absent. Not inferred from the history of submitted reviews. |
| CI summary | GraphQL `statusCheckRollup.state` | Combined check-run and commit-status state for the PR head; nullable. |
| PR comment count | GraphQL `totalCommentsCount` | Provider-reported total, independent of the subset displayed in Discussion. |
| Issue comment count | REST issue `comments` | Issue conversation count. |
| Branches and change totals | GraphQL head/base names, additions, deletions, changed files, commit total | Tied to the returned PR snapshot. |
| Created/updated/closed/merged timestamps | REST / GraphQL timestamps | Preserve provider timestamps; compact date uses their UTC date. |
| Check and review history | Existing REST check-runs, statuses, reviews | Retained in Checks alongside their provider state identifiers. |

The implementation follows the official [REST pull request reference](https://docs.github.com/en/rest/pulls/pulls), [REST issue reference](https://docs.github.com/en/rest/issues/issues), [GraphQL pull request schema](https://docs.github.com/en/graphql/reference/pulls#pullrequest) and [GraphQL status rollup schema](https://docs.github.com/en/graphql/reference/commits#statuscheckrollup). The query was also executed against a public Neovim PR: nullable review decision, successful CI, comment count and change totals decoded independently.

## Freshness and boundaries

A REST page receives one bounded GraphQL enrichment request for up to 100 PRs; there are no per-row subprocesses. The enrichment requests scalar metadata, not duplicate bodies. Partial GraphQL errors, missing nodes, identity mismatches and mixed update snapshots are visible failures. The error banner reserves multiple lines so the provider diagnostic is not hidden behind a generic summary. Selected details additionally require the same immutable head as the REST revision. No automatic retry was added.

The account-scoped metadata cache namespace is version 3 and retains its 30-second TTL. Explicit refresh invalidates cached metadata. In-memory detail navigation remains a snapshot until refresh; summary badges are not live monitors. Estimated cache cost includes the new strings and collections. Review writes still validate fresh remote revisions and do not trust summary badges as authorization.

Projects, reactions, linked issues and derived checklist progress are outside this change. They are not represented as fetched or empty provider data. Projects can require additional permissions, and counting Markdown checkboxes is not a replacement for provider task state. Press `o` to inspect the original item on GitHub.

## Verification

The final Debug run executed 98 tests with zero failures or skips. Coverage includes batched enrichment, nullable states/counts, partial errors, mixed snapshots, density configuration, row capacity and independent viewport scrolling. The Release build and code signature verification succeeded. Format, localization (138 strings across five locales), third-party notices (24 resolved packages), REUSE and whitespace checks passed.

Release PTY suites passed for workspace/cache reuse, Vim motions, search/review, feature controls, Unicode editors, presentation and wheel/scrollbar behavior. A read-only live GitHub run against `neovim/neovim` verified list enrichment and rich Overview. Screenshots were rendered from SwiftTerm terminal cells for all four palettes, comments, forms and density modes; this does not establish physical terminal font rendering or trackpad feel.

On 2026-09-11, the executable was installed at `$HOME/.local/share/tatara/local/bin/tatara`. Build and installed SHA-256 both equal `2b7b9a03a7161a99b2b99a8708105a7b062cf85fa8bd61d7befb7bb540579204`. The installed executable passed the presentation suite and rich-density wheel suite. Existing processes must be restarted to use it. Detailed logs are in `.artifacts/modern-*.log`; terminal snapshots are in `.artifacts/swift-pty/presentation/` and `.artifacts/swift-pty/metadata-live/`.


### Installed rich-mode navigation measurement

A 176 x 48 Release PTY run completed 114 observations with rich rows, a synthetic large document, cold preparation and reused caches. Input replay included alternating PR/file motions at 25 ms and 120 ms intervals. The measured response ends at synchronized terminal output; burst figures measure the final Help response after queued motions, not each individual key.

| Observation | Median | p95 | Maximum |
| --- | ---: | ---: | ---: |
| PR selection, settled | 2.53 ms | 14.92 ms | 14.92 ms |
| PR selection, preparation in flight | 1.55 ms | 2.44 ms | 2.48 ms |
| File selection, settled | 1.73 ms | 2.05 ms | 2.05 ms |
| File selection, preparation in flight | 6.33 ms | 7.43 ms | 9.30 ms |
| Diff source cursor | 2.49 ms | 6.39 ms | 6.39 ms |
| Diff search through completed results | 157.95 ms | 162.45 ms | 162.45 ms |

The synchronous input trace recorded 361 samples: median 0.254 ms, p95 1.075 ms and maximum 20.648 ms. This measures synchronous input handling, separately from preparation and terminal output. Cold ready-state observations reached 5.17 seconds for PR metadata/Overview and 4.63 seconds for files with intentionally slow fixture subprocesses, including a four-second difftastic delay. Those values are fixture behavior, not a live GitHub latency claim. PR burst Help tails were at most 5.38 ms; file burst tails were at most 10.88 ms. Search results still took about 160 ms in this workload.

The current TermLoom profiler uses `TATARA_INPUT_TRACE`; `--legacy-frame-diagnostics` is an explicit opt-in for archived SwiftTUI comparison binaries. Artifacts: `.artifacts/swift-pty/navigation-modern-installed-rich-final/navigation.json` and `input.tsv`. These observations establish this workload only and do not measure physical display presentation or trackpad feel.
