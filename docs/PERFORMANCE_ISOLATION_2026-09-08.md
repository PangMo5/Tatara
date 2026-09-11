# Responsiveness isolation — September 8–9, 2026

This investigation follows the SwiftTUI 0.11.3 dependency update. It tests the
reported slow scrolling and input during loading without migrating the renderer.

## Conditions

- Apple M4 Max, macOS 27.0; Release, `-O` and whole-module optimization verified
  for SwiftTUIGraph, SwiftTUICore, and SwiftTUIRuntime. No `DEBUG` define.
- The running installed executable had SHA-256 `9de9c49b175bb3f6c99b27e72e70380633cf93e5501e93d542563c0e579a0e18`;
  the updated Release had `b2062154299a6cf9071040d1716cc19b9ce949e713bdbaf81d3e12edd5aa2008`.
  The user's process was not interrupted or replaced.
- Actual terminal size was 104 × 56. Unless stated otherwise, experiments use
  that size, isolated synthetic caches, a roughly 2.5 MB PR body, and 25,000 diff
  rows. Scrolling samples begin after the document is ready.
- Each scrolling run records 40 alternating half-page inputs; minimal-counter
  runs record 80 inputs after 20 warm-up inputs. Completion requires a closed
  synchronized PTY output frame. CPU sampling was a separate run.
- These are controlled synthetic PTY observations, not a LazyGit comparison or
  a measurement of the terminal application's compositor. A single paired run's
  maximum is not a statistically stable regression estimate.

## Sequential experiments

| Experiment | Median input-to-visible-output | Finding |
| --- | ---: | --- |
| Installed vs updated Release, scrolling | 49.98 → 49.52 ms | The old running binary is real, but an update alone does not remove this scrolling cost. |
| Async vs sync renderer, 320 × 64 | 77.33 → 73.16 ms | Switching execution modes alone has little effect. |
| Styled vs plain viewport | 49.78 → 49.22 ms | Removing syntax styles/rich-text construction is insufficient. |
| Styled vs empty viewport | 49.78 → 40.30 ms | Most latency remains without painting the document. |
| Minimal SwiftTUI counter, diagnostics on/off | 2.63 → 2.48 ms | The framework has no universal 40 ms input floor; logging is not a large fixed delay. |
| Full workspace with diagnostics off | 55.36 ms | Diagnostic logging is not necessary for the slow behavior. |
| Minimal local state vs real TCA reducer with 25,000-row document | 2.376 → 2.382 ms | Reducer execution and retaining a large document do not explain the slow full workspace. |
| Full workspace vs hidden sidebars, preserving document width | 55.38 → 30.33 ms | PR/file-pane structure contributes substantial cost even during document scrolling. |
| Default vs disabled measure-cutoff pre-pass | 55.38 → 56.09 ms | The pre-pass switch alone is not a useful remedy. |
| Original vs isolated Equatable sidebar-row view | 56.34 → 57.92 ms | Snapshot equality at this boundary did not remove the cost. |

Rows belonging to a pair used the same executable and workload. Separate pairs
used successive diagnostic builds, so their absolute medians should not be
combined into an additive cost model. Empty viewport and hidden sidebars are
ablations, not proposed product behavior or full functional validation.

A terminal-size environment prototype moved work out of GeometryReader's layout
realization but did not reliably remove it: 48.62 ms median, 95.92 ms p95 after
correct initial viewport synchronization. An earlier run with the default 100 × 24
model viewport was invalid and excluded. The prototype was not adopted.

## Clock alignment and internal phases

Input tracing was extended with `frame_started_ms`, using the same
`MonotonicInstant` origin as SwiftTUI's `committed_at_ms`. Matching the final 40
scroll inputs to frames gave medians of approximately:

| Boundary | Time |
| --- | ---: |
| Framework input arrival → application key handler | 0.063 ms |
| Synchronous application `Store.send` | 0.186 ms |
| Key handler completion → frame commit | 52.64 ms |
| Existing core blocked+suspended timing fields | 17.74 ms |

The last row does not cover the complete renderer invocation. It must not be
interpreted as the full main-thread or frame cost.

An isolated copy of the resolved SwiftTUI source added timestamps around actual
runtime calls. Representative steady scrolling frames showed:

- Frame acquisition: roughly 46–50 ms.
- Head preparation: roughly 2 ms.
- Late-preference/layout coordination: roughly 22 ms, including an approximately
  18.5–19 ms first layout pass and a roughly 2.15 ms subsequent pass. The inexpensive
  final worker-layout timing does not account for the first pass.
- Raster tail: roughly 10–12 ms.
- Commit: roughly 14 ms. The transaction commit itself accounts for about 3 ms;
  subsequent artifact publication/retained-frame work accounts for roughly 9 ms.
- Focus synchronization: roughly 0.02–0.03 ms.
- Presented-surface damage comparison: roughly 2.2–2.6 ms.
- Terminal output: roughly 0.23–0.25 ms.

The CPU sample contains substantial raster-cell/style copying and comparison.
However, direct phase timing disproved the earlier suspicion that the final
presented-surface comparison explained the entire missing interval. Sampling
shows where CPU is spent; it does not independently assign the wall-clock gap.

## Conclusion and remaining scope

The dominant measured cost is the real workspace's view-tree/layout coordination
and frame commit/publication, with an additional raster cost. Neither TCA state,
large-document retention, syntax coloring alone, logging, nor async scheduling
alone explains it. Removing sidebars changes the cost materially; merely wrapping
their rows in an Equatable value view does not.

This supports concentrating subsequent work on the presentation representation
and the renderer's layout/publication machinery. It does not establish that a
specific Rust/Ratatui port will meet a latency target. A port should first render
the same viewport with Swift state retained and replay the same inputs.

After restoring the upstream source and normal UI, a separate cold-navigation
fixture alternated j/k twenty times before each detail/diff read could finish.
All twenty PR samples and all twenty file samples still reported loading or
preparation in the completed frame. PR selection was 52.23 ms median / 59.10 ms
maximum; file selection was 40.45 ms median / 121.06 ms maximum. These are
key-to-selection-feedback measurements, not network completion timings. They
confirm the reported in-flight selection delay in a controlled fixture; the
user's exact live PRs and files were not replayed.

That run started 22 diff processes in total, compared with two in the warmed
navigation fixture. Snapshot fetching was reused, but repeated uncached
selection still starts and cancels producers. This is a separate source of
redundant external work to investigate; the count alone does not establish how
much of the frame latency it causes.

## Evidence and restoration

Raw samples, snapshots, CPU sample, clock joins, source patches, and preserved
experimental executables are under `.artifacts/responsiveness-root/` and
`.artifacts/swift-pty/`. The source probes are saved as `application-probes.patch`
and `swift-tui-timing.patch`; `tatara-experiments` and `tatara-smoke-experiments`
retain the diagnostic variants. The shared package cache was never modified.
The workspace dependency symlink and normal UI implementation were restored.
Only shared-clock input tracing, optional diagnostics-free profiling, and the
cold-navigation workload remain in the normal source tree. The restored Release
passed 62 tests and the real-difftastic/demo PTY checks.


## Loading-burst follow-up — September 9

The subsequent report identified PR/file-list `j/k` as worse than diff scrolling,
with a perceived delay near one second that grows during repeated input. The
per-key cold-navigation experiment above waited for selection feedback before
sending the next key. It cannot establish responsiveness under continuous input.

The follow-up added independent 25 ms keyboard replay during loading, then a
larger synthetic fixture (100 PRs, 120 files) and directional `j` runs of 8, 32,
and 64 inputs. Each run checks the final selected index and records selection
at every completed synchronized PTY frame. It measures the final navigation key
directly, instead of substituting the help key after alternating `j/k`.

The user's active terminal was 104 × 56, running the installed executable in
a separate application worktree. The existing session was left running. A separate read-only
live replay used that repository's first two open PRs and first two files; it
does not establish the latency of every PR/file the user may have selected.
No forge writes were performed. The synthetic runs use isolated caches and
delayed fixture subprocesses; the live run uses ordinary account-scoped caching.

The installed binary's small alternating fixture measured 66–80 ms after the
last help key for PRs and 78–130 ms for files. The live replay measured 99–129 ms
for PRs and 88–133 ms for files; only the first live file burst started while
loading, and subsequent file bursts were already ready. These are help-response
measurements, not evidence that selection remains smooth throughout a burst.

In the dense directional fixture on the installed binary, all 208 navigation
inputs contributed to the correct final selection. Synchronous key handling
was at most 0.42 ms. File selection advanced several rows at a time, with gaps
up to 170 ms between visible selection changes. Final-key-to-final-selection
latency was 232–243 ms for files and 102–109 ms for PRs. This establishes visibly
lagging selection under load in this fixture, but does not reproduce a one-second
freeze or show an unbounded input queue. A single run at each burst length is
not a statistically stable p95 estimate.

Raw evidence is under `.artifacts/swift-pty/navigation-loading-burst-installed/`,
`navigation-live-loading-burst-installed/`, and
`navigation-loading-burst-directional/`. `navigation.json` stores replay timing,
loading status, and per-frame selected indices; `input.tsv` measures synchronous
application handling. The PTY includes emulator parsing and excludes the actual
terminal compositor/display. The helper uses list mode and stable output; it
does not establish parity with tree-mode selection or physical key-repeat feel.


A fresh XcodeBuildMCP Release build of the current source also passed the same
replay. Its SHA-256 was
`5cd6bf15f1af70d09a3fbbc1c9229ff810fb97b4ab3cea6a2140e80a02abc603`.
The helper's final source was rebuilt before this run.

| Directional burst | Installed PR | Current PR | Installed file | Current file |
| --- | ---: | ---: | ---: | ---: |
| 8 inputs | 108 ms | 92 ms | 232 ms | 218 ms |
| 32 inputs | 109 ms | 78 ms | 239 ms | 278 ms |
| 64 inputs | 102 ms | 123 ms | 243 ms | 277 ms |

Values measure the last `j` write through the completed frame showing the final
selected index, not replay duration or final document readiness. Current-source
file selection updates had gaps up to 208 ms. All 208 directional inputs were
handled, with at most 0.36 ms of synchronous application handling. The current
run started 108 fixture diff processes versus 26 on the installed version across
the full navigation suite; that difference is additional external work, not a
measurement of its contribution to latency. The current-source artifacts are in
`.artifacts/swift-pty/navigation-loading-burst-directional-current/`.

The dense experiment initially exposed a helper assumption: it waited for the
literal status `Ready`, whereas a full PR page renders `L · Load more` after
loading. That failed run is excluded. The helper now accepts either completed
status. The final directional replay and focused SwiftFormat checks passed.
This follow-up changes measurement tooling and documentation, not application
behavior. It does not establish that the reported one-second interaction has
been fixed; the loaded user's executable was neither replaced nor stopped.
