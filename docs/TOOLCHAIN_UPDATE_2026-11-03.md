# Toolchain and dependency refresh — November 3, 2026

## Toolchain and formatting

- [Xcode 27.2 (27B52)](https://developer.apple.com/news/releases/?id=10292026a),
  Apple Swift 6.4.2 and macOS 27.2 SDK. The deployment
  target remains macOS 15; building with the current SDK does not raise it.
- SwiftFormat 0.64.5 with the October 29 Airbnb configuration at
  [`341e154`](https://github.com/airbnb/swift/blob/341e15448fce4c28aa8d36af171f39ab98b2913b/Sources/AirbnbSwiftFormatTool/airbnb.swiftformat).
  Project overrides select Swift 6 language mode, preserve SPDX headers and
  exclude generated code, package checkouts and build products. Guard-like test
  conditionals are preserved because SwiftFormat 0.64.5 otherwise replaces a
  trailing conditional assertion block with an unconditional `#require`. The
  initial full test run exposed this at widths 100 and 140; restoring the original
  test semantics and changing that formatter option fixes the cause.
- Tuist 4.214.1, GitHub CLI 2.103.3, difftastic 0.72.0, Jujutsu 0.46.0,
  uv 0.13.7, Gitleaks 8.30.1, REUSE 6.2.0 and mise 2026.10.25.
- CI uses `xcode-27`, with pinned current Actions versions and a toolchain check
  before dependency resolution. The local mise environment selects Xcode without
  changing the system-wide Command Line Tools selection.

The toolchain check runs before generation, builds and tests. Selecting Xcode
26.6 is rejected explicitly. The compiler language setting remains Swift 6 with
complete strict concurrency; package manifests now require Swift tools 6.4.

## Resolved updates

| Package | Previous | Current |
| --- | --- | --- |
| [grdb.swift](https://github.com/groue/GRDB.swift) | 7.11.1 | 7.12.0 |
| [sqlite-data](https://github.com/pointfreeco/sqlite-data) | 1.12.0 | 1.12.1 |
| [swift-collections](https://github.com/apple/swift-collections) | 1.6.0 | 1.7.5 |
| [swift-concurrency-extras](https://github.com/pointfreeco/swift-concurrency-extras) | 1.4.1 | 1.4.3 |
| [swift-dependencies](https://github.com/pointfreeco/swift-dependencies) | 1.17.1 | 1.17.2 |
| [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing) | 1.19.4 | 1.19.7 |
| [swift-subprocess](https://github.com/swiftlang/swift-subprocess) | 1.0.0 | 1.0.2 |
| [swift-syntax](https://github.com/swiftlang/swift-syntax) | 603.0.2 | 604.0.0 |
| [swift-toml](https://github.com/mattt/swift-toml) | 2.0.0 | 2.1.0 |
| [termloom](https://github.com/Frank-III/termloom) | b746967794ad | ff6dd74f7daa |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | 1.20.0 | 1.99.2 |

SwiftTerm now also resolves `h` 1.0.1, `swift-png` 4.5.2 and ArgumentParser
1.8.2. All direct and transitive dependencies were checked against their upstream
stable releases. TCA remains at the current stable 1.26.2. TermLoom has no tagged
release, so its latest default-branch commit is pinned immutably. Both lockfiles
and third-party notices were regenerated.

## TermLoom integration

The current upstream adds an event-driven idle loop and queued-input presentation.
It still lacks horizontal wheel events and Tatara's opt-in bounded wheel rendering
batches. The existing patches were ported to the new input pump while preserving
upstream's indefinite idle wait, cancellation wakeup and queued-event handling.
Lookahead never expires an incomplete Escape sequence. Batches retain every input
transition, clamp and direction reversal, and stop at keyboard/pointer boundaries.

Patch application was replayed against pristine upstream files in a temporary
checkout and validated against the expected output SHA-256 values. No obsolete
patch implementation remains alongside the updated one.

The universal Release build succeeds with Xcode dependency-scan warnings in five
upstream macro targets (TCA, Dependencies, Perception and StructuredQueries).
These warn about undeclared SwiftSyntax module edges in the generated package
graph. There are also two `libtool` notices for the symbol-free shim object.
The warnings are retained in `.artifacts/build-release.log`; they are not hidden
or converted into a toolchain fallback.

The PTY demo now waits for the committed Normal-mode footer after closing the
review editor. Its previous generic PR label also appeared inside the editor,
so it could send the next key before Escape had completed. The helper now
synchronizes on the actual interaction state without adding a settling delay.
Viewport assertions also identify the dedicated PR selection sidebar explicitly;
the Files sidebar is required only in the review workspace.

## Repository

The existing Git history is retained in a colocated Jujutsu workspace. The remote
is the public [`PangMo5/Tatara`](https://github.com/PangMo5/Tatara) repository.
Contributor guidance documents `jj` changes, `pangmo5/` task bookmarks and explicit
bookmark pushes. Before publication, the four prior project commits were
rewritten with a GitHub noreply author/committer address while retaining their
original author dates and commit descriptions. Personal machine paths, a local
worktree identifier and a local-only experiment branch namespace were removed
from historical documents. A stale link to an unshipped prototype was also
converted to historical prose. The separate active worktree and its branch were
preserved; only the cleaned `main` ancestry is published. CI now scans the full
fetched history with Gitleaks. No signed binary release was published.

## Validation

- Universal Release build succeeded for arm64 and x86_64 with Xcode 27.2
  (27B52), Swift 6.4.2 and the macOS 27.2 SDK; the executable reports 0.1.0.
- 126 Swift Testing tests in 15 suites passed. This includes live difftastic
  0.72.0 decoding and the updated TermLoom scroll/cancellation integration.
- Nine Release PTY scenarios passed: demo, PR selection/quick picker, workspace,
  wheel axes/margins, features/presets, editors, stress, search/review and
  wide-line PR/file navigation bursts. Four themes and all five locales passed.
- Formatting, 182 localized strings across five locales, notices for 26 resolved
  packages plus Catppuccin, REUSE and whitespace checks passed.
- Gitleaks found no credentials in the pre-publication history. A fresh bare
  clone from GitHub also passed: five commits scanned, no credential findings,
  no private-workspace/personal-path matches and no personal iCloud author email.

The navigation run used a 320 × 64 PTY, synthetic delayed `gh`/`difft` processes,
warm PR/file replacements and eight 21,000-character source rows. It recorded
114 observations, including 25 ms and 120 ms input bursts. PR/file in-flight p95
was 1.79/5.14 ms; diff cursor p95 was 3.36 ms and content search p95 was 240.31 ms.
The final help key after a 25 ms PR/file burst had maxima of 4.88/5.12 ms. Cold
readiness took 2.19/4.16 seconds, separately from immediate selection feedback.
Other builds were observed on the host, so these are functional timing evidence,
not an isolated before/after performance comparison. Synchronous reducer tracing
is saved separately from completed synchronized terminal output in
`.artifacts/swift-pty/navigation-latest/`; this does not measure physical display
or compositor latency.

The first [hosted CI run](https://github.com/PangMo5/Tatara/actions/runs/41574431318)
stopped at the stable Xcode build check. GitHub's `xcode-27` image still lists the
27B48 release candidate, while the required and locally validated release is
27B52. That app-build requirement was subsequently limited to signed binary
releases. Ordinary CI validates Xcode 27.2, Swift 6.4.2 and macOS SDK 27.2 and logs
the actual app build. It can verify the same compiler/SDK on the hosted RC without
claiming the app is the stable release. `validate-release` and `release-build`
still require 27B52. No older compiler or SDK is substituted.
