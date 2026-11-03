# SwiftTUI frame publication experiment

> Historical investigation. Commands, dependencies and UI descriptions reflect the
> date of this report. See the [README](../README.md) and [architecture](ARCHITECTURE.md)
> for the current supported behavior.


## Decision

Moving immutable frame preparation ahead of main-actor publication is feasible
without changing SwiftTUI's public view API. This experiment passes the upstream
repository gate, but does **not** establish a navigation performance improvement.
Do not enable it in Tatara or submit it as a performance improvement PR on the
current evidence. No upstream PR was opened for this experiment.

The candidate remains in the local SwiftTUI experiment checkout on
`frame-publication-preparation`, commit
`9dac3c8b1d85fe3b9e30b7ef704d2e1880e8921b`. Its base is SwiftTUI 0.12.1,
`2c250a5ef383d42bf990b532a20a25d0477b02ef`.
A standalone patch is saved at
`.artifacts/frame-publication/frame-publication-preparation.patch`.
These local artifacts are ignored by Git; the patch is not part of Tatara's
shipping dependency graph.

## What was transferred

The [renderer comparison](RENDERER_COMPARISON_2026-09-09.md) used a compact
viewport snapshot, a renderer actor, and a latest-pending-frame handoff. This
experiment applies the immutable preparation/publication separation to the
existing SwiftTUI runtime, preserving its graph and lifecycle semantics:

- Build retained indexes, draw-node membership, surface topology, phase
  signatures and scroll routes with the existing frame-tail worker.
- Carry those products in the completed frame candidate. Publish them only
  after the existing stale/drop acceptance checks.
- Read the committed retained state directly under a short mutex instead of
  synchronously entering the worker executor.
- Share the surface metadata within a frame instead of traversing the same
  placed tree for each consumer.
- Use iterative index traversal. The first worker-preparation version exposed
  a stack overflow in the existing deep-tree test; the final version passes
  that test and preserves duplicate-ID traversal/overwrite ordering.

Preparation of a discarded frame can do work that the previous accepted-frame
publication path avoided. This remains a tradeoff, not a free scheduling change.

## Controlled Tatara A/B

Both binaries run the full SwiftTUI Tatara UI. The baseline contains the earlier
observed-key invalidation change at `1c359c27`; the candidate adds only this
frame-publication experiment. The TermLoom prototype is not involved in this A/B.

Each variant ran three times at each terminal size: 12 runs total. Runs used
100 PRs, 120 files, 8/32/64 downward navigation keys at 25 ms spacing in both
panes, and 16 diff paging keys. Configuration and data/cache directories were
isolated, and all selection and paging assertions passed. Measurements ran
without concurrent compilation or CPU profiling.

The metric pairs each actual PTY input write with the first completed synchronized
terminal frame that includes that motion. It is not the harness's overall burst
completion time. Each table entry pools three runs: 312 PR inputs, 312 file inputs
and 48 paging inputs per variant/size. Lower is better.

| Terminal | Operation | Before p95 | Candidate p95 |
| --- | --- | ---: | ---: |
| 104 × 56 | PR selection | 81.28 ms | 88.72 ms |
| 104 × 56 | File selection | 147.56 ms | 137.31 ms |
| 104 × 56 | Diff paging | 52.15 ms | 52.08 ms |
| 320 × 64 | PR selection | 107.05 ms | 109.35 ms |
| 320 × 64 | File selection | 221.73 ms | 215.84 ms |
| 320 × 64 | Diff paging | 81.52 ms | 95.88 ms |

File-selection tails improve slightly, PR selection does not improve, and large
terminal paging regresses in this sample. This does not justify claiming a
general responsiveness gain. It also does not reproduce the TermLoom prototype's
latency or prove the user's original roughly one-second stall has been fixed.

The synchronous TCA send p95 remains approximately 0.3 ms. Input-to-handler queue
tails remain approximately 55–60 ms at 104 columns and 80 ms at 320 columns.
The experiment changes retained-frame preparation, not that queueing behavior.

## Why worker preparation was insufficient

The macOS event pump enqueues input during an in-flight frame. The outer run loop
dispatches the events after that frame path returns. Freeing the main actor during
part of preparation therefore does not automatically let the application process
and present a newer selection.

SwiftTUI also still resolves and lays out its rich view graph. The TermLoom
comparison executable renders a smaller immutable viewport representation and
does not provide full SwiftTUI lifecycle, preferences, focus, editor, review or
accessibility behavior. The renderer comparison cannot be treated as evidence
that swapping raster storage alone would preserve those features at the same
speed.

A separate upstream-only `termui-perf` run compared stock 0.12.1 with the candidate
using `file-browser-selection`, async mode, 24 rows, 104 × 56 and ten iterations
per variant. Its preliminary median CPU/frame was 74.5 versus 74.0 ms, with
input-to-commit p95 medians of 144.8 versus 148.7 ms. Part of the first variant
overlapped compilation of the summary helper, so these numbers are corroborating
diagnostics, not the controlled performance result above.

An additional stock Release run was sampled for ten seconds at 1 ms intervals.
The profile contains substantial retain/release, value-copy and measurement
work. The lifetime-anchor counters show about 73,651 visits/replacements per
run, of which about 73,202 replacements are no-ops. Those counts identify repeated
work; they do not prove that removing those walks is safe or that they dominate
latency. Anchor projection also reads live parent/hosting facts, so a cache keyed
only by the resolved value would not establish valid invalidation.

The next architectural investigation would need explicit ownership of committed
input routes versus in-flight graph state, plus bounded frame preparation.
Dispatching through a graph while it is being reconciled requires a correctness
design before it can replace the current event queue.

## Verification and evidence

- Final SwiftTUI `bun run test`: PASS, including graph/core/views, runtime,
  async frame tail, lifecycle, platform packages, tooling and policy gates.
- Added tests cover preparation remaining unpublished, discarded candidates not
  advancing retained state, and final GeometryReader geometry in both sync and
  async rendering.
- Tatara feature PTY checks passed for tree/list navigation, selection ranges,
  review preview, presets and quit. No forge writes were performed.
- The temporary dependency symlink was restored to Tatara's existing pinned
  `1c359c27f6bc983a436df80db9f6df3bbc7c3df0` source archive. All tracked source
  files were checked against that commit. This experiment does not change the
  dependency manifest or the installed application.
- Regeneration and the restored Tatara Release build passed. XcodeBuildMCP's
  temporary Release session setting was returned to Debug.

Local evidence:

| Artifact | Purpose |
| --- | --- |
| `.artifacts/frame-publication/navigation-summary.json` | Controlled A/B summary |
| `.artifacts/swift-pty/navigation-publication-{before,after}-{104,320}-{1,2,3}/` | Raw navigation and synchronized terminal frames |
| `.artifacts/frame-publication-gate-final.log` | Passing final upstream gate |
| `.artifacts/frame-publication-depth-tests.log` | Focused depth and publication tests |
| `.artifacts/frame-publication/features-after.log` | Full-UI feature smoke |
| `.artifacts/frame-publication/framework-perf-progress.log` | Preliminary native framework comparison |
| `.artifacts/frame-publication/framework-cpu-sample.txt` | Sampled stock framework stacks |
| `.artifacts/frame-publication/profile-run.log` | Profile workload completion |

Binary SHA-256:

- Baseline: `db55d1ddfd65bef7dc9cb2100e768adab36e0eaf7523827be9d234fd108ff209`
- Final candidate: `a6628ec41ce0a475a05da7c0661c624de2d1231d402d0c147ca3f54119ff884e`

The earlier candidate that failed the deep-tree test is excluded from the final
A/B. Its failure log is retained; it is not a successful validation run.
