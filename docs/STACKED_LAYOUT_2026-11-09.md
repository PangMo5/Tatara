# Narrow review workspace — November 9, 2026

Below 100 columns, the review body is split evenly into Files above and Content
below. The two full-width panels remain visible while Tab/Shift-Tab changes focus.
An odd spare row belongs to Content. Global header/footer rows remain outside the
split. The dedicated PR-selection screen keeps its existing presentation.

WorkspaceGeometry supplies rendering, pointer hit testing and viewport dimensions.
The hidden current-PR summary has an empty hit region in the stacked layout, so
clicking Files cannot accidentally open the PR picker. Wheel input targets the
panel under the pointer without changing selection, source cursor or focus.

Both narrow and wide layouts retain document/source identities, pinned paths and
independent pane offsets. A source-anchored composer uses the available body when
the lower pane cannot contain the inline panel; resizing preserves its text and
anchor, and saving restores the stacked workspace.

159 Release Swift Testing tests passed, including 60/80/99-column layouts at
16/27/40 rows, equal bounds, simultaneous panels under either focus, the unchanged
selector screen and a constrained source-anchored composer. The --stacked PTY
covers ordinary PR entry, focus changes, file clicks, wheel ownership, small-window
composition and restoration to a wide layout. It performs no forge writes.

Raw screenshots and checks: `.artifacts/swift-pty/stacked/`.


## Release PTY measurements

The synthetic two-file PR includes published comments. Screenshots cover
80 × 30, 96 × 28, 60 × 16 and 99 × 40 workspaces, plus an 80 × 20 composer.
The 24 focus-feedback observations run at 99 × 40 after initial file preparation,
with stable output and both panels visible. Screenshot capture occurs outside
these timing samples. No compiler, sampler or preview recorder ran alongside
samples; unrelated host workload was uncontrolled.

Tab-to-completed-terminal-frame p95/max was 1.70/1.83 ms. Separately, 43
instrumented root-key Store.send calls had synchronous p95/max
0.20/0.44 ms. Initial file readiness after entering the PR was
131.29 ms, including input, synthetic preparation and terminal output.
These are single-run observations, not real GitHub timings or a comparative speed
claim. The terminal-frame boundary includes emulator parsing and does not isolate
compositor paint or terminal-write CPU.

Executable SHA-256: `f7700cfee0d50ef60e4359ef3032345f5fa304c3c7c15ebdbe4cc320beb0f7f8`.

The regression suite also covers duplicate comment-reader requests. Source/width
identity coalesces an existing preparation instead of cancelling and restarting
it when fresh context arrives unchanged. A gated worker test verifies one call,
no cancellation and successful document publication.
