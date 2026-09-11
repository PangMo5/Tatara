# PR and file navigation implementation

September 9, 2026. Implements the first two stages of
[the responsiveness proposal](RESPONSIVENESS_DESIGN_2026-09-09.md).
The proposed 16/33 ms selection and 50 ms burst-tail targets remain unmet.

## Confirmed causes and changes

SwiftTUI 0.12.1 retains the dispatch-backstop behavior inspected in 0.11.3.
A minimal runtime regression delivers four observed selection writes before a
frame. Observation's first write schedules its readers; subsequent writes do
not produce another one-shot callback. Automatic dispatch consequently requests
root invalidation. The pre-change test fails on that root-invalidation assertion.
Actual Tatara dispatch traces also identify dispatch-backstop root invalidations.

The framework change adds an explicit `KeyPressInvalidationPolicy.observedState`
contract to `onKeyPress`. The existing overloads retain automatic invalidation.
The policy travels with the consuming handler through registration, restoration,
and fingerprinting. Mixed observed/untracked handlers retain the conservative
redraw for the untracked event. Observed no-op events need no new frame.
Tatara opts in because its visible keyboard effects go through observed state;
termination and opening a link use the existing runtime actions.

The dependency is pinned to
[`PangMo5/swift-tui` commit `1c359c27`](https://github.com/PangMo5/swift-tui/commit/1c359c27f6bc983a436df80db9f6df3bbc7c3df0),
based on upstream 0.12.1. Tuist resolves the remote commit; development did not
modify the shared package source cache.

Tatara derives pane bounds from the terminal-size environment and initializes
the document viewport on appearance, then updates it on size changes. This
removes selection-driven geometry realization. Sidebar rows share line limits,
style text before framing, and draw one noninteractive selection background per
pane. File labels no longer acquire selection-dependent background subtrees.

Loading now assigns its final loading state once. Document currency first checks
the preparation phase, avoiding generation dependencies while already loading.
Empty content-search matches are cleared only when nonempty: mutating the nested
TCA field through `_modify` otherwise notifies readers even when the resulting
dictionary is still empty. Observation tests cover absent and existing empty
search state, and verify that a real content response still notifies readers.

## Valid intermediate measurements

Release PTY, 104×56, 100 PRs, 120 files, loading fixture, 8/32/64 consecutive `j`
keys at 25 ms intervals. Values below are milliseconds from the final key write
to synchronized terminal output displaying the expected final selection. Each
cell is one burst, not a statistically meaningful p95. All final indices match.

| Build | PR 8 / 32 / 64 | Files 8 / 32 / 64 |
| --- | --- | --- |
| Stock SwiftTUI 0.12.1 | 127 / 104 / 76 | 214 / 237 / 279 |
| Explicit observed-key contract only | 114 / 113 / 137 | 186 / 175 / 185 |
| Combined app changes | 61 / 62 / 42 | 87 / 102 / 79 |

Evidence: `.artifacts/swift-pty/navigation-update-0121`,
`navigation-observed-keys`, and `navigation-search-guard`; each contains input
timestamps, frame diagnostics, selection samples, binary SHA-256, and snapshots.
These runs were made without concurrent builds or CPU sampling.

Early geometry prototypes (`observed-size`, `observed-rows`, `compact-rows`,
`currency`, `steady-loading`) had an unsynchronized model viewport and are
excluded. The smoke helper now checks document row capacity and wrapped fixture
text continuity. The old prototype fails this check; the corrected implementation
passes at 104×56, 80×30, and 160×42, including returning to 104×56.

The reported one-second freeze was not reproduced. PTY output verifies terminal
transactions, not the physical terminal/display experience. Remaining frame-tail
work needs separate measurement before extending the framework optimization.

## Final pinned Release

Binary SHA-256:
`db55d1ddfd65bef7dc9cb2100e768adab36e0eaf7523827be9d234fd108ff209`.
These runs followed all compilation and framework tests, without CPU sampling.
The same 8/32/64-key loading bursts produced:

| Terminal | PR 8 / 32 / 64 (ms) | Files 8 / 32 / 64 (ms) |
| --- | --- | --- |
| 104×56 | 60 / 46 / 44 | 67 / 107 / 90 |
| 320×64 | 54 / 67 / 81 | 113 / 178 / 177 |

Each row reflects 208 directional input events; all six final selected indices
match the sent counts. These are single-burst tail measurements, not p95 claims.
At 104×56, the 208 synchronous keyboard-handler samples have p95 0.320 ms and
maximum 3.509 ms. This isolates handler duration from terminal presentation.
At 320×64, twelve additional alternating-direction bursts at 25/120 ms intervals
all reached the subsequent help view; its maximum response delay was 138 ms.

Evidence: `.artifacts/swift-pty/navigation-pinned-final-104` and
`navigation-pinned-final-320`. The smaller terminal improves on the stock
0.12.1 comparison above, but larger-frame costs and the original acceptance
targets remain open.

## Validation

- The framework's `bun run test` policy, API baseline, Foundation-free layering,
  runtime, platform, tooling, and soundness checks passed. The runtime shards
  executed 180, 837, and 2,635 tests. The first run exposed two graph-totality
  assertions whose expected fingerprint namespaces omitted the new key policy.
  After updating that expectation, `bun run test --lane core` passed, including
  2,384 non-runtime tests and the isolated runtime, launch, and tooling checks.
  Logs: `.artifacts/responsiveness-implementation/framework-gate.log` and
  `framework-core-final.log`. The final change after the first run was limited
  to that graph-test expectation.
- Remote resolution regenerated the Tuist workspace. All 15 changed dependency
  files match the committed source; the resolved path is an immutable revision
  cache, not the development checkout. Transitive dependency pins are unchanged.
- The pinned Release build passed with no warnings. Format, localization,
  dependency notices, and REUSE checks passed (`swift Scripts/Tatara.swift lint`).
  The notice generator now handles revision-only package headings without a
  trailing space. XcodeBuildMCP executed all 65 app tests successfully against
  the pinned Release build, with zero warnings and zero skipped tests.
- PTY feature checks passed: tree/list configuration, collapse/expand, active
  borders, Shift-V source ranges, both diff sides, review preview, pointer actions,
  persistent presets, and quit. No forge writes were performed.
  The final pinned binary also passed pane search, help, wheel/scrollbar movement,
  paging, Escape, persistent-cache reuse across processes, and viewport/text
  continuity at 104×56 → 80×30 → 160×42 → 104×56.
