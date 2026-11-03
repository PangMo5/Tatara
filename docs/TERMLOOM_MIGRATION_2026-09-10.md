# Production TermLoom migration — September 10, 2026

> Historical investigation. Commands, dependencies and UI descriptions reflect the
> date of this report. See the [README](../README.md) and [architecture](ARCHITECTURE.md)
> for the current supported behavior.


Tatara's production executable now uses TermLoom. The pinned upstream revision is
`b746967794ad2753c39f695f5923c5cdf2f6425a`. SwiftTUI has been removed from the runtime
package graph and the former SwiftTUI view definitions have been replaced.

## Implementation

- `TerminalWorkspace` implements the native `TerminalApplication` protocol.
  TermLoom owns raw mode, input decoding, control focus, observable-state redraw,
  buffer comparison, synchronized output and terminal restoration.
- `TerminalScreen` and the presentation files construct viewport-sized native
  widgets. Text fields, multiline review editors and buttons use TermLoom's
  interaction map. The TextArea module is built from the same pinned checkout.
- TCA still owns workspace, filter and review state. `gh`, difftastic,
  SQLiteData, immutable source identities, cancellation and generation checks
  remain in their existing modules. There is no Rust bridge or alternate
  prototype executable in the production path.
- Four Catppuccin themes, five languages, Vim bindings, tree/list navigation,
  pane search, help, scrollbars, mouse input, review marks, both source sides,
  linewise selections and persistent presets remain connected to the real app.
- Saved drafts reenter editing with confirmation cleared. This fixes a retained
  confirmation state that could select the submit control when opening another
  inline editor. The regression is covered in the TCA review workflow test and
  the real PTY feature sequence.
- Complete submission previews are wrapped on a worker, generation-checked and
  scrollable after resize. Submission controls appear only after preparation.
  Native editor cursor/selection changes do not rejoin the entire draft string;
  content edits update the TCA draft. Long comment lists have paging controls.
- ASCII decoration and no-color modes preserve authored source text. Mouse
  placement handles terminal-cell widths, including CJK input. The accessible
  cursor follows pane focus and native editing controls.

## Reproducible dependency graph

`Tuist/Package.swift` and `Tuist/Package.resolved` select upstream TermLoom directly.
The TextArea subpackage references the root package locally, so `Project.swift`
compiles that module's sources from the resolved checkout against the same core.
No ignored experiment directory or machine-specific checkout is required.

The smoke harness still depends on SwiftTerm. Its independent lockfile is now
resolved by the generation command and included in notice generation. Runtime
and test-helper versions are deduplicated only when identity and revision match.

## Validation

- XcodeBuildMCP Release build passed without warnings.
- All 65 Swift Testing/TCA tests passed, with zero failures and zero skipped tests.
- PTY feature checks passed: tree/list configuration, active borders, Shift-V
  ranges, LEFT/RIGHT anchors, review preview, draft reopening and saved presets.
- PTY editor checks passed: multiline paste, undo/redo, mouse cursor movement,
  ASCII source preservation, no-color output, complete long previews and resize.
- Demo checks passed for four themes, five languages and terminal restoration.
- Workspace checks passed for pane search, help, mouse wheel, scrollbar, paging,
  resize, Escape and persistent cache reuse across processes.
- Large-text and in-flight-diff focus checks passed. Separate viewport checks
  verified initial and resized ranges against continuous source text.
- Formatting, 108 catalog entries across five locales, third-party notices and
  REUSE checks passed. The final notice set covers 24 resolved packages plus
  Catppuccin.

All PTY write flows used synthetic data. No forge write, pull request, push or
release publication was performed. Remote submission behavior was tested through
injected clients; a live review was not posted.

The PTY helper previously assumed a nonblocking write consumed every byte. The
long-paste check exposed partial writes and duplex backpressure. It now completes
writes while draining output, and reports input failures explicitly. This does
not add a settling delay to key-to-frame measurements.

SwiftTerm's translated cell text omitted the tested ZWJ emoji even though its
complete UTF-8 sequence was present in ANSI output. The check verifies emitted
bytes separately; it does not claim physical-terminal emoji rendering coverage.

## Measurement method

The final comparison uses the previously installed SwiftTUI executable and the
final production TermLoom executable, not the earlier simplified prototype.

- SwiftTUI SHA-256: `0bb94ef8153c16b22efb3a14c3ae1d022e1499c4f2d1a5584fd2677acbd23f4f`.
- TermLoom SHA-256: `42964fd36e8803ed089f2a8eda72f1bb5d79ece0d0206a9d83a031a853167cb2`.
- Terminal sizes: 104 × 56 and 320 × 64 cells.
- Three alternating A/B pairs per size, twelve processes total.
- A dense fixture supplies 100 PRs and 120 files. Each pane receives directional
  bursts of 8, 32 and 64 inputs at a nominal 25 ms interval while loading.
- Each input is paired with the first completed synchronized PTY frame whose
  selection includes that motion. All inputs must contribute to the final index.
- Per pane, size and executable: 312 input observations; 48 page-scroll samples.
  There are 2,688 observations across the comparison.
- Separate configuration/cache state is used per run. Builds, tests, diagnostics,
  recording and profilers are not run alongside the timing sequence.

These are selection-feedback and page-rendering measurements. They do not say
that remote detail acquisition or complete diff preparation finishes in a few
milliseconds. The PTY includes emulator parsing and excludes compositor/display
refresh and physical keyboard/trackpad feel. Other desktop applications remained
active, so outliers and repeated runs are retained.

## Final results

Pooled p95 input-to-visible-selection and page-rendering latency, milliseconds:

| Size | Interaction | SwiftTUI | TermLoom |
| --- | --- | ---: | ---: |
| 104 × 56 | PR selection | 70.29 | 1.50 |
| 104 × 56 | File selection | 108.01 | 3.91 |
| 104 × 56 | Diff paging | 41.62 | 2.12 |
| 320 × 64 | PR selection | 84.56 | 2.24 |
| 320 × 64 | File selection | 159.98 | 4.73 |
| 320 × 64 | Diff paging | 74.48 | 4.37 |

The largest final TermLoom observation was 16.14 ms during file selection at
320 × 64. The equivalent SwiftTUI maximum was 193.55 ms. All twelve final runs
completed with no omitted input and no excluded incomplete run.

Raw evidence is under `.artifacts/swift-pty/navigation-termloom-final-{renderer}-{width}-{round}/`.
The pooled summary is `.artifacts/termloom-migration/final-comparison-summary.json`;
its `source_reports` array identifies the exact twelve inputs. Earlier migration
runs are retained separately and are not pooled into these final results.

A separate input-trace run recorded 240 synchronous store sends: median
0.254 ms, p95 0.396 ms, maximum 3.413 ms. This is reducer and
synchronous cancellation time; external acquisition and preparation run separately.
The trace is not pooled into the twelve uninstrumented timing runs.

## Local delivery

The normal local `tatara` installation is updated from the measured Release
product. The preceding executable and its complete shared-data directory are
backed up before replacement. Installation verifies the signature and version,
replaces the executable atomically and records source/renderer identity. Running
processes must be restarted to load the new executable.
