# SwiftTUI responsiveness: maintainer review package

> Historical investigation. Commands, dependencies and UI descriptions reflect the
> date of this report. See the [README](../README.md) and [architecture](ARCHITECTURE.md)
> for the current supported behavior.


## Review question

Can an application process input against its committed interaction state while
an immutable frame is being prepared, without changing SwiftTUI's authoring API
or losing state, focus, lifecycle effects, or ordered termination?

The proposal should answer that question with an upstream-only reproduction,
deterministic correctness tests, a complete application comparison, and a clear
accounting of costs. A large diff is justified only where its parts establish
that behavior together. This document is a working evidence index; pending items
are not passing results and the structural candidate is not yet PR-ready.

## Existing evidence and its limits

| Evidence | What it establishes | What it does not establish |
| --- | --- | --- |
| [Renderer comparison](RENDERER_COMPARISON_2026-09-09.md) | The same Tatara state/data pipeline can support much faster navigation through a smaller immutable viewport tree and independent input/render scheduling. | Full SwiftTUI API or feature parity; an isolated TermLoom renderer speedup. |
| [Frame-publication experiment](SWIFTTUI_FRAME_PUBLICATION_EXPERIMENT_2026-09-09.md) | Immutable retained-frame preparation can move to the worker while preserving the tested commit/drop contracts. | A consistent navigation improvement: the controlled A/B is mixed. |
| Direct user trials | The user reports a noticeable improvement with the frame-publication build and a much larger improvement with the TermLoom prototype. | Controlled timings or proof that all configurations improve. Record this as user feedback. |
| `InputDuringFrameTailTests.inputDoesNotWaitForHeldRaster` | On the baseline, an actual injected key cannot update live state while a previous raster is held; the test fails before the gate is released. | A latency percentile or success of the replacement implementation. |

The controlled renderer comparison reports 104 × 56 file-selection p95 of
132.47 ms for the complete SwiftTUI UI and 3.18 ms for the TermLoom prototype.
At 320 × 64 the corresponding values are 193.03 and 5.67 ms. These motivate the
investigation, but must never be presented as the improvement of the proposed
SwiftTUI PR. The PR needs its own before/after numbers using the same complete UI.

The baseline failing test is captured in
`.artifacts/frame-publication/input-during-tail-before.log`: one Swift Testing
test executes and fails at the pre-release state assertion. The raster is held
by a gate, so its timeout is a failure bound, not a performance threshold.

## Architectural argument

The current frame head already stages runtime registrations and preserves live
state mutations across asynchronous tails. Input still waits in the event pump
until the frame returns. Moving work off the main actor does not by itself
remove that wait.

The candidate must make the ownership boundary explicit:

1. Resolve/evaluation and prepared graph materialization remain exclusive.
2. Only a worker suspension with committed graph state restored can dispatch
   new input. Bootstrap has no committed interaction surface and must finish
   before dispatch is enabled.
3. Input changes live state and schedules the latest desired frame; it does not
   launch a second renderer or mutate the worker's snapshot.
4. A dispatch receipt carries the outcome back to the outer driver. The driver
   owns flushing and termination and must never execute the handler again.
5. Frame acceptance preserves mutations made after preparation. An old candidate
   cannot claim to have displayed a newer input or publish speculative routes.
6. Layout that requires a materialized graph stays exclusive. Its cost remains
   visible rather than being hidden behind unsafe concurrent dispatch.

This is an input and frame-ownership change. A wholesale replacement of the
layout algorithm, public view API, or lifecycle system is not required to test
that hypothesis. Additional graph/layout changes need separate measured reasons
even if they ultimately belong in the same PR.

## Correctness matrix

Every new behavioral test must run against the real `RunLoop` and input stream.
Calling a state mutation closure directly is useful lower-level coverage, but
does not prove that queued keyboard input can make progress.

| Contract | Required reproduction | Existing related coverage | Candidate evidence |
| --- | --- | --- | --- |
| Input progress | Hold raster, send another key, observe state before release. | `AsyncFrameTailRenderingTests` | Baseline fails; first candidate passes the same test. |
| Exactly-once dispatch | Several keys during one held frame; final count equals sent keys. | `FrameworkStressInputRoutingTests` | Authored 17-key held-raster burst passes, with and without GeometryReader. |
| Authored state | `.onKeyPress` mutates `@State` during a held frame; commit and drop both preserve it. | `AsyncFrameTailRenderingTests`, `ObservationDraftWindowRuntimeTests` | Authored burst passes in default/ordered variants; related regression set passes. |
| Focus and editing | Type, paste, traverse focus, and edit while a prior frame is held. | `AppRuntimeTests`, `FrameworkStressInputRoutingTests` | Pending. |
| Exclusive graph evaluation | A GeometryReader/late-preference pass cannot expose draft routes to input. | `AsyncFrameTailRenderingTests`, `RetainedFramePublicationTests` | Pending. |
| Lifecycle | A departed view's task is cancelled once; retained tasks and state survive. | `DormantTabStateTests`, `ViewportLifecycleMigrationTests`, `StaleBaselineFrameHeadTests` | Pending. |
| Exit ordering | Key changes followed by quit/EOF/signals; no input after accepted exit; cancelled termination remains interactive. | `AppRuntimeTests`, termination and terminal-handoff suites | Held-raster quit and cancelled-quit cases pass. Full signal/handoff matrix still pending. |
| Frame provenance | Inputs received after preparation are attributed only to a frame that can contain them. | Input-arrival and frame diagnostics tests | Pending. |
| Bounded work | One render in flight; repeated input schedules a latest state, not one render task per key. | Cancellation and frame-pipeline stress suites | Pending. |
| Existing contracts | Focus, pointer, gestures, overlays, animation, platform and API policy gates. | `bun run test` | Must rerun after the final code change. |

The earlier retained-frame experiment's passing gate cannot be reused as a
passing gate for the input-dispatch changes.

The first focused input/state/termination/async-tail regression run executed
78 Swift Testing tests successfully. Its log is
`.artifacts/frame-publication/input-during-tail-regressions-final.log`.
An earlier run failed the existing test that expected every computed frame to
be presented even in the default mode. New input can now supersede a visual-only
frame while its worker runs. That test now explicitly selects `.asyncNoDrop` to
retain coverage of ordered publication; the new default-mode tests exercise
the changed scheduling behavior. This expectation change belongs in the PR's
review notes, not in an unexplained test-baseline update.

## Performance and preview protocol

The final evidence should have three separate layers:

- **Upstream reproduction:** a small SwiftTUI view and a `termui-perf` scenario
  with no Tatara, TCA, GitHub credentials, or application fixture dependency.
- **Complete application:** unchanged Tatara views and source workload against
  pinned baseline and candidate framework revisions.
- **User-visible preview:** recorded terminal output and exact input sequence
  from synthetic data. A TermLoom recording is a separately labelled reference.

For the complete application, preserve the existing 100-PR/120-file fixture,
8/32/64-key bursts at 25 ms, 25,000-line sources, 104 × 56 and 320 × 64 sizes,
fresh isolated data/cache, and repeated runs with rotated order. Also reproduce
the user's normal tree/list configuration and intermittent short input bursts;
the existing long directional replay may not explain the reported improvement.

Record p50, p95, maximum, sample count and failures for:

- input arrival to handler and synchronous handler duration;
- actual PTY input write to completed synchronized output;
- frame head, layout, raster, publication and output;
- CPU/frame, peak or high-water memory, frame count, skipped/dropped work;
- cold and warm preparation, paging, resize, and repeated interaction bursts.

A preview is not a performance run. Recording, CPU sampling and extra tracing
must run separately from the quiet timing comparison. Show identical terminal
dimensions and inputs, preserve stalls, and label any changed playback speed.
The final preview must contain the actual framework candidate, not the simplified
TermLoom UI substituted under its name.

Report regressions as prominently as gains. A faster handler alone does not
prove faster visible feedback; fewer frames can also conceal delayed feedback.
The independent user's original roughly one-second symptom remains unproven
until its actual workload is reproduced.

## Reproduction and artifact manifest

The final package should identify:

- upstream base and candidate commit IDs, separate optional observed-key patch;
- Swift/Xcode version, OS/architecture, build mode and relevant environment;
- executable and native-library SHA-256 values;
- exact build, test, benchmark and preview commands;
- raw machine-readable timings, stdout/stderr, failing and passing test logs;
- screenshots/recordings and the script that generated their input;
- explicitly excluded runs with reasons; no silent omission of failed runs.

Existing entry points are `swift Scripts/Tatara.swift renderer-prepare`,
`renderer-bench LABEL`, and `renderer-summary LABEL`; the prototype instructions
are in the archived prototype README. These compare application
paths and must not replace an upstream-only reproduction.

Upstream uses `swiftly run swift ...` with Swift 6.3.3 and `bun run test` for the
repository gate. Local Xcode-toolchain adaptation is machine-specific and should
not be prescribed to maintainers whose pinned toolchain already works.

Only synthetic repository data should enter public previews and test artifacts.
Keep local paths, account identifiers, tokens and unrelated worktree contents out
of the PR attachments.

## PR presentation

Lead with the reproducible symptom, the before/after behavior and the ownership
contract. Then show the minimal example, actual complete-UI measurements,
architecture diagram, regression matrix, and limitations.

Explain each commit's necessity: worker preparation and bounded publication;
input/driver ownership and exactly-once outcomes; state/lifecycle/termination
regressions; benchmark and preview tooling; architecture documentation. Remove
obsolete paths that the accepted design replaces.

SwiftTUI's current `CONTRIBUTING.md` says changes scoped to one behavior or
subsystem are most likely to land. A large PR should therefore remain about this
single responsiveness contract, with reviewable commits and a reproducible
acceptance argument. Do not add unrelated cleanup to increase its scope.
