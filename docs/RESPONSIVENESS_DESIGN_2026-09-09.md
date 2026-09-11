# Responsive PR and file selection

Design proposal, September 9, 2026. The original proposal is preserved below;
implementation evidence is tracked in
[the implementation report](RESPONSIVENESS_IMPLEMENTATION_2026-09-09.md).
This proposal targets SwiftTUI source, not Apple's closed-source SwiftUI renderer.

## Evidence and first hypothesis

The loading-burst measurements in
[the isolation report](PERFORMANCE_ISOLATION_2026-09-08.md) show final file
selection feedback at 218–278 ms on the current Release, despite synchronous
application key handling below 0.36 ms. The reported one-second freeze remains
unreproduced. Existing viewport slicing, document preparation workers, and
`DocumentViewport: Equatable` already address several ordinary application costs.
Earlier experiments found no meaningful benefit from an Equatable row wrapper
or simply replacing the root geometry reader with a size environment value.

Joining the existing current-Release 64-key runs to frame diagnostics gives:

| Workload | Committed frames | Fresh raster with `root_invalidated` | Layout realization / cache hits / main-actor fallback |
| --- | ---: | ---: | --- |
| PR selection | 23 | 21 | 1 / 0 / 1 in every frame |
| File selection | 15 | 14 | 1 / 0 / 1 in every frame |

The counts establish ineffective reuse in this interaction. They do not identify
which invalidation source caused the root sweep.

**First hypothesis: repeated input can defeat precise Observation invalidation.**
`RunLoop+EventDispatch.swift` samples the scheduler's invalidation-request
generation before calling a key handler. `requestDispatchBackstopInvalidation`
in `RunLoop+PostCommitSupport.swift` requests root invalidation if that generation
did not change during the handler. Meanwhile, `ObservationBridge.track` uses
`withObservationTracking`, with a callback that queues the observed identity;
tracking is re-established by evaluation. A second mutation before evaluation
can therefore receive no new one-shot callback even though the first mutation
already scheduled the correct readers. The dispatch check can mistake that for
an untracked side effect. This fits burst degradation but requires a targeted
test and invalidation-source trace before being called the root cause.

## 1. Fix the invalidation contract before replacing views

Use a minimal observed selection with two visible rows and deliver multiple keys
before a frame. Compare single-key, same-direction burst, and alternating burst
dispatch. Record precise observation identities, dispatch backstops, root
escalations, and resulting selected indices. Also run the actual Files pane.

If the hypothesis is confirmed, make dispatch distinguish a handler with
declared observed-state effects from a handler with unknown effects. One possible
API is an explicit invalidation policy on `onKeyPress`; this is a proposed API,
not an existing SwiftTUI option. Tatara's TCA navigation handler can opt into the
observed-state contract once all of its visible effects are verified. Preserve
the existing conservative behavior for unknown/untracked mutations.

Do not merely suppress all root invalidations whenever any frame is pending.
A batch can mix an observed update and an untracked change elsewhere. Nor should
the framework drop repeated keys: every motion must update the model in order.
The renderer may combine their presentation into a single current frame.

Test observed-only, untracked-only, mixed handlers, mixed effects within one
handler, no-op boundary navigation, background responses, and modal key routing.
Reused frames must carry correct lifecycle and interaction registrations.

## 2. Separate geometry, row content, and transient presentation in Tatara

Keep Swift and TCA as the state and effect owners. Split presentation inputs into:

- **Geometry:** terminal dimensions, pane bounds, and viewport capacity. Changes
  on resize or an actual screen-layout transition.
- **Row content:** stable IDs, sanitized labels, indentation, review marks, and
  text metrics. Changes when the list/filter/tree expansion/content changes.
- **Selection:** selected ID, visible-window offset, focus, and loading label.
  Changes frequently during keyboard input.

Have the smallest relevant views read these values. Stable labels should not be
sanitized and reconstructed just because selection changes. Maintain a bounded
presentation cache keyed by source revision, width, locale, and tree/filter
state; keep theme-dependent style separate from source text where possible.

The objective is a measured reduction in invalidated identities and computed
nodes, not merely more view structs. Passing the same Store to several views is
not itself proof of broad observation; inspect the properties actually read and
their attributed view identities. Keep the existing bounded document viewport.

Isolate root geometry from changing selection dependencies. Investigate why
`GeometryReader`'s layout-realized content is regenerated at unchanged bounds.
Preserve live child dependency updates while reusing geometry. A size-only cache
that suppresses real child changes would be incorrect. The previous size-
environment prototype is evidence against treating a mechanical replacement as
the complete fix.

## 3. Make stable-size selection reuse layout through SwiftTUI's pipeline

SwiftTUI already implements selective graph evaluation, retained layout,
incremental raster damage, worker layout/raster stages, and input draining
between frames. Extend and repair these paths instead of adding parallel caches
or a second event loop.

For a selection move within a fixed viewport, prove that bounds, row metrics,
content topology, and layout-dependent preferences are unchanged. Reuse measured
and placed products, update the old/new row decoration and selection semantics,
and rasterize only the resulting damage. A window shift must update visible
content and row hit targets; it cannot reuse old row identity mappings.

Retain one synchronized terminal commit that agrees with the input/focus state.
Do not paint selection directly to stdout outside the frame transaction. Loading
may retain an identified old document preview, but that preview must not provide
review anchors or search matches for the new selection.

If ordinary row views still create too much graph work after invalidation is
fixed, prototype one text-cell viewport primitive for Files only. Its immutable
row payload and explicit selection/scroll inputs should make retained layout
eligibility provable. Keep keyboard, pointer, focus, and accessibility semantics.
SwiftTUI's existing `Canvas` is a graphical cell-sampling primitive with image
semantics; converting all text to Canvas is not an equivalent implementation.

## 4. Reduce publication work after reuse starts working

`publishCommittedFrame` calls `FrameTailRetainedState.storeCommittedFrame` on
the main actor. The latter prepares retained indexes, topology signatures, phase
signatures, and a draw-node index while holding its state lock. Shape-stable
`RetainedFrameIndex` patching already exists, but several node-ID tables still
rebuild because IDs may have multiple structural occurrences.

Prepare immutable candidate metadata on the worker using an explicit baseline
generation. At commit, validate that generation and atomically publish the
matching candidate together with its surface and semantic products. Keep work
that accesses actor-owned graph/registrations on the main actor. Do not move an
arbitrary existing closure across actors or retain a lock during expensive work.

Prefer structural occurrence keys and deltas for unchanged subtrees where the
ownership proof permits them. Preserve collision behavior and compare optimized
products with full-rebuild oracles in tests. Re-measure this stage after fixing
root invalidation; the earlier approximately 14 ms publication/commit observation
is a prioritization clue, not a promised amount of recoverable time.

## 5. Bound obsolete loading work separately

Maintain immediate selection state, generation-checked results, cooperative
cancellation, and bounded active/pending producers. Pending work should retain
the latest request for its ownership scope. Check freshness before process
launch and before expensive parsing. Never hold a UI-shared lock while waiting
for process teardown. Deduplicate requests for the same immutable content.

This does not guarantee that every short-lived process disappears: if a request
has already started before the next key arrives, cancellation still has a cost.
The current suite's 108 diff launches versus 26 on the installed binary warrants
separate investigation, but does not prove it causes the presentation delay.
Do not introduce input blocking, arbitrary debounce delays, or retries to hide it.

## Implementation order and acceptance

1. Reproduce and attribute dispatch backstops with a minimal observed-state
   burst. Fix the invalidation contract if confirmed, then replay the real pane.
2. Narrow Tatara presentation dependencies and geometry realization. Verify
   that stable-size selection avoids root invalidation and retains layout.
3. Reduce remaining worker/publication costs. Add a Files text viewport
   primitive only if existing declarative rows remain the measured bottleneck.
4. Address producer admission/cancellation as a separately measured change.

Run each experiment independently before combining successful changes. Preserve
existing UI behavior. Use an isolated dependency checkout or maintained fork;
ship dependency changes through a pinned revision and regenerated Tuist project,
not edits to a package cache.

Proposed acceptance targets, not current results: p95 key-to-visible-selection
at most 16 ms for selection inside a stable viewport, at most 33 ms when its
window moves, and no more than 50 ms of catch-up after a sustained burst. Measure
enough samples to report tails meaningfully. Keep document-ready/network latency
separate. Validate the actual problematic PR/file sequence in tree and list
modes, cold and warm caches, 104×56 and a larger terminal, direction changes,
resize, Unicode/wide cells, help/search/review overlays, and pointer interaction.
Tests and PTY output do not establish physical terminal/display feel.

Apple's [SwiftUI performance guidance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)
supports narrowing update dependencies and separating geometry work from state
that does not affect layout. It informs the app-side design; it is not evidence
that Apple's renderer behavior or Instruments SwiftUI lanes apply to SwiftTUI.

## Source map

All dependency paths below are relative to
`Tuist/.build/checkouts/swift-tui/Sources/` at the inspected resolution.

- Tatara: `TataraTUI/Sources/WorkspaceView.swift` and
  `TataraKit/Sources/WorkspaceFeature.swift`.
- Dispatch: `SwiftTUIRuntime/RunLoop/RunLoop+EventDispatch.swift`,
  `RunLoop+PostCommitSupport.swift`, and `RunLoop+EventPump.swift`.
- Observation: `SwiftTUIViews/Environment/Observation.swift`.
- Geometry: `SwiftTUIViews/GeometryReading/GeometryReader.swift`,
  `SwiftTUIRuntime/Rendering/LatePreferenceReconciliation.swift`, and
  `FrameTailLayoutOffloadEligibility.swift`.
- Reuse/publication: `SwiftTUIRuntime/Rendering/FrameTailPresentationDamage.swift`,
  `FrameTailRetainedState.swift`, `DefaultRenderer+CompletedFrameCandidates.swift`,
  and `SwiftTUICore/Commit/RetainedFrameIndexPatching.swift`.
