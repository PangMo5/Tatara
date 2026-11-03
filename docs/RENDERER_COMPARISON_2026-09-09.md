# SwiftTUI, TermLoom and Ratatui renderer comparison

> Historical investigation. Commands, dependencies and UI descriptions reflect the
> date of this report. See the [README](../README.md) and [architecture](ARCHITECTURE.md)
> for the current supported behavior.


September 9, 2026. **TermLoom is the most promising candidate for the next
Tatara UI migration experiment.** It preserved Swift authoring and consistently
reduced measured navigation and paging latency in this prototype. This is not
yet evidence that the complete review application has been ported or that its
physical terminal experience is solved.

## Existing implementations investigated

| Candidate | What it supplies | Fit for Tatara |
| --- | --- | --- |
| [TermLoom](https://github.com/Frank-III/termloom) | Swift result builders, widgets, immediate layout/buffers, ANSI backend, optional observation runtime | Closest existing implementation to the requested Swift-authored UI; measured below. Independent Swift code inspired by Ratatui, not Rust bindings. No release tags were available at inspection. |
| [ratatui-ffi](https://github.com/holo-q/ratatui-ffi) | Existing C ABI for Rust Ratatui, widgets, layout, events, batched frames | Reused for the Rust experiment, so the Rust renderer was not rewritten. Integration quality needs work: the checked-in cbindgen config failed with 0.29.4; generated C contained duplicate enum names and Rust generic fields. The batch draw path also omits some paragraph/list settings. |
| [swift-bridge](https://github.com/chinedufn/swift-bridge) | Generates Swift/C glue from Rust bridge declarations | Useful interop machinery, not a ready SwiftUI-to-Ratatui view layer. Not needed for this small existing C ABI surface. |
| [UniFFI](https://github.com/mozilla/uniffi-rs) | Multi-language Rust bindings, including Swift | Another binding generator, not a terminal UI authoring/runtime layer. |
| [Tint](https://github.com/alleato-llc/tint) | Independent Swift immediate-mode widgets inspired by Ratatui | A simpler alternative, but its inspected API is less aligned with the requested SwiftUI-style authoring than TermLoom. Not benchmarked. |
| [ratatui-kit](https://github.com/yexiyue/ratatui-kit) | Rust components, hooks, reconciliation, input routing over Ratatui | Requires Rust UI authoring and introduces another component runtime. Not a direct fit for retaining Swift views. |

GitHub repository searches for `ratatui language:Swift`, `swift ratatui`, and
`ratatui ffi`, plus the sources above, did not reveal a ready, drop-in SwiftTUI
API-compatible Ratatui binding. This is a bounded search result, not a claim that
no such project exists anywhere.

## Measured implementation

The archived prototype (not included in the current source tree) retains the actual
`WorkspaceFeature`, forge/cache clients, cancellation and ownership checks, and
`DocumentRenderer`. The two experimental backends receive the same immutable
Swift result-builder tree and use the same input/coalescing driver. TermLoom
owns its layout, frame buffer and output; Ratatui owns layout and output through
the existing FFI. Worker actors own rendering; TCA remains on the main actor.

This isolates the two experimental renderer integrations reasonably closely.
Comparing either with the complete SwiftTUI application also changes view-tree
complexity, runtime scheduling and interaction metadata. It is an application
path comparison, not a pure Rust-versus-Swift or framework microbenchmark.

Pinned sources and binaries:

- SwiftTUI: upstream 0.12.1 plus the observed-key patch at
  [`1c359c27`](https://github.com/PangMo5/swift-tui/commit/1c359c27f6bc983a436df80db9f6df3bbc7c3df0).
  Binary SHA-256 `db55d1ddfd65bef7dc9cb2100e768adab36e0eaf7523827be9d234fd108ff209`.
- TermLoom: [`b7469677`](https://github.com/Frank-III/termloom/commit/b746967794ad2753c39f695f5923c5cdf2f6425a).
  Core sources compiled directly into an optional Tuist target without modifying
  the upstream source. Initial compilation emitted an upstream Calendar
  Sendable-metatype warning; this experiment does not exercise Calendar.
- ratatui-ffi: [`ccadaa7b`](https://github.com/holo-q/ratatui-ffi/commit/ccadaa7bdcfb42ab1b7994abb434ef5948615e78),
  with its locked Ratatui 0.30.0 dependency. Its native-host Release build passed
  with five upstream warnings. A small audited C header is local to the probe.
  Native library SHA-256:
  `d3c61e34249e27279bb29af4ff49f3dc477ecb733c077174e20290b48b30ecc9`.
- Both experimental modes use binary SHA-256
  `8ec75f6d90afb88e80fbb76966bd1ac16953247aee272587e35b628edd09a49f`.
  The backend is recorded separately in each measurement report.

## Workload and measurement definition

Release builds on the same Mac; no concurrent build, framework test, or CPU
sampling during measured runs. Fixtures contain 100 PRs, 120 changed files,
large overview text and 25,000-line source files. Each process gets fresh
data/cache storage. The measured configuration is Mocha, standard keys and
English. Three runs per backend per terminal size rotate backend order.

Each run sends 8, 32 and 64 consecutive `j` events at 25 ms intervals in both
PR and file panes while replacement content loads. The final selected index is
checked after every burst, and the selection is reset between bursts. Each
backend/size therefore has **312 PR inputs, 312 file inputs and 48 paging
samples**. All 3,744 directional inputs across the 18 primary runs matched their
expected final selections; no observed selection moved backwards during a burst.

For each input, latency is measured from its actual PTY write timestamp to the
first completed synchronized terminal frame whose selected index includes that
motion. Coalesced frames can represent several inputs. These are terminal
transaction measurements, not physical display latency.

The old `latency_ms` field on a whole burst measures when the harness finishes
waiting. For already-rendered fast inputs it can include an extra read wait of
about 20 ms. The tables use the recorded input/frame pairing instead, so that
wait is not attributed to the renderer. Raw records retain both kinds of data.

## Results

All values below are milliseconds; PR/file columns are **per-input p95** over
312 samples, paging is p95 over 48 samples.

| Terminal | Backend | PR selection | File selection | Diff paging |
| --- | --- | ---: | ---: | ---: |
| 104×56 | SwiftTUI | 81.46 | 132.47 | 54.76 |
| 104×56 | TermLoom | **1.11** | **3.18** | 3.21 |
| 104×56 | Ratatui FFI | 131.88 | 10.78 | **1.30** |
| 320×64 | SwiftTUI | 93.98 | 193.03 | 79.78 |
| 320×64 | TermLoom | **2.01** | **5.67** | **1.81** |
| 320×64 | Ratatui FFI | 6.39 | 11.29 | 2.78 |

The Rust integration was usually fast, but one 104×56 run contained a PR-input
maximum of **316.94 ms** and a worker draw duration of **302.32 ms**. That run is
included, not discarded. Ratatui's layout cache is thread-local while a Swift
actor can execute successive jobs on different threads; thread affinity is a
specific follow-up hypothesis, not an isolated or confirmed cause of the spike.
Do not generalize this result to an optimized native Rust Ratatui application.

TermLoom's PR maximum across the three 104×56 runs was 3.83 ms; its file maximum
was 27.67 ms. At 320×64 the corresponding maxima were 3.41 and 7.52 ms. These
results support continuing with TermLoom; they do not promise a universal
sub-16-ms bound for all future UI features or real repositories.

## Correctness and retained evidence

- The experimental Release built successfully. All 65 existing app tests passed
  with zero failures/skips, and format, localization, notice and REUSE checks
  passed. `renderer-prepare` was also executed successfully after implementation.
- All 12 settled overview/diff comparisons (two sizes, three runs, two screens)
  matched source text across the three renderers after removing the source
  cursor indicator and trailing cell padding. `renderer-fidelity.json` records
  this check. Borders, missing interaction decorations and accessibility are
  deliberately not claimed equivalent.
- Both experimental modes passed initial viewport, row-capacity and continuous
  wrapped-text checks while resizing 104×56 → 80×30 → 160×42 → 104×56.
- Three additional long-line runs, one per backend at 320×64, passed all
  directional selection checks. Their nine-row source fits vertically, so
  vertical paging is explicitly inapplicable. An earlier harness attempt tried
  to page this non-scrollable document and failed; that incomplete run is
  excluded and listed in the summary. The large primary comparison instead
  uses the scrollable 25,000-line fixture.
- Review submission is disabled in the experimental client. Review/filter
  editors, complete keyboard routing, mouse interaction, help, accessibility,
  all themes and complete SwiftTUI semantics remain migration work.

Artifacts are under `.artifacts/swift-pty/navigation-renderer-v1-*-104-*`,
`navigation-renderer-v2-*-320-*`, and `navigation-renderer-wide-*`.
`.artifacts/renderer-comparison-summary.json` contains counts, medians, p95,
maxima, source report paths and the excluded incomplete run. Experimental
`input.tsv` and `renderer-stages.tsv` separate reducer, snapshot and worker draw
costs. Data is written after the measured interaction rather than during it.

Reproduce the primary workload with `renderer-build`, `renderer-bench LABEL`,
and `renderer-summary LABEL` through `Scripts/Tatara.swift`. The recorded run
set used labels `renderer-v1` for 104×56 and `renderer-v2` for 320×64. The final
benchmark command additionally isolates configuration to preserve the default
settings on machines with user customization.

The next implementation step is to port the real Tatara screens onto native
TermLoom widgets, preserving source coordinates, preview ownership, review
confirmation, text editing, localization and input behavior, then repeat these
measurements with that complete UI.
