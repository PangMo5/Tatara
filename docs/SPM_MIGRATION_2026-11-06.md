# SwiftPM migration — November 6, 2026

Tatara now builds from the root `Package.swift`, without Tuist or a generated
Xcode project. Existing module boundaries and macOS 15 deployment remain intact.
Remote dependency revisions are unchanged; TermLoom is now a local source package.

## Source and build contracts

- `Package.resolved` records remote dependencies. The PTY helper retains its own
  lockfile, and `resolve --locked` checks both through SwiftPM.
- TermLoom's 42 core/TextArea files were compared with upstream revision
  `ff6dd74f7daaef393480c24de734c1435719ad46`. Only the three documented wheel-axis
  and scroll-presentation changes differ. Its license and provenance are retained.
- Tests import the executable's presentation code instead of compiling duplicate
  source files. `TataraVersion.current` supplies both CLI and release versions.
- Architecture selection uses `--arch`. A versioned `--triple` incorrectly raised
  dependency deployment targets and exposed unavailable Perception bindings.
  Dependencies retain their declared deployment targets; Tatara itself targets 15.
- Builds query `swift build --show-bin-path`, then prepare an independent runtime
  in `.artifacts/products/CONFIGURATION-ARCH`. SwiftPM outputs are not modified.
- Apple's `swift-stdlib-tool` copies `libswiftCompatibilitySpan.dylib` beside
  `tatara`. Prepared executables retain system/loader-relative library search
  paths, with Xcode and build-directory paths removed. Installation, signing,
  notarization and packaging consume the executable and companion library.

## Metadata mapping

| Former project setting | SwiftPM configuration |
| --- | --- |
| macOS deployment target 15.0 | `macOSDeploymentTarget` in `Package.swift`; validated against the executable's Mach-O header |
| macOS SDK / Xcode 27.2 | `macOSSDKVersion`, mise's `DEVELOPER_DIR`/`SDKROOT`, and toolchain checks; the final linker explicitly records SDK 27.2 |
| Swift 6 / complete strict concurrency | `swiftLanguageModes: [.v6]` |
| Default `nonisolated` | Explicit `.defaultIsolation(nil)` on every Tatara target |
| Product/version | `tatara` and `TataraVersion.current` (`0.1.0`) |
| Code signing identifier | `dev.PangMo5.tatara` for both ad-hoc and Developer ID signing |
| Dead-code stripping | SwiftPM's enabled default, confirmed in the actual Debug and Release link commands |
| English development language / five locales | Existing catalog, generated Swift table and localization validation |

The metadata audit found that a correct SDK path alone did not preserve the
Mach-O SDK version in this Swift Build/toolchain combination: the executable
initially recorded SDK 15.0 despite compiling against SDK 27.2. The final link now
declares both the deployment target and SDK version. Every scripted build compares
the executable's recorded values with the evaluated package platform and selected
SDK, failing explicitly on a mismatch. SDKROOT is also passed through mise and
script subprocesses.

Xcode project organization, static-framework bundle identifiers, generated
Info.plist settings and automatic localization-extraction flags are retired.
Native package modules, the compiled version constant and the existing explicit
catalog workflow supply the corresponding runtime behavior.

## Local validation

Validated with Xcode 27.2 build 27B52, Swift 6.4.2 and macOS 27.2 SDK on an arm64
Mac running macOS 27.3 (26C5035r).

- Debug and Release builds; 126 Swift Testing tests across 15 suites.
- Both arm64 and x86_64 Release executables and archives: architecture checks,
  ad-hoc signature verification, extracted companion libraries and `--version`.
  The x86_64 executable ran through host translation.
- Isolated local installation and relocation; missing runtime files are rejected.
- Release PTY scenarios: demo, rich PR selection/picker, workspace/cache reuse,
  wheel axes, tree/review features, multiline editors, source search/review, and
  large-input/in-flight focus changes. All eight final scenarios passed.
- Locked resolution, seven toolchain contracts, SwiftFormat, five-locale catalog
  validation, third-party notices and REUSE.

The final 176×40 stress run measured 201 focus-feedback samples: median 44.55 ms,
p95 95.50 ms, maximum 96.56 ms. It used synthetic forge/diff fixtures with fresh
application data/cache directories, after the cross-build had completed; compiler
and OS caches were warm and other host workloads were uncontrolled. Preparation
duration and terminal-output time were not measured independently. These are PTY
scenario results, not a real-repository performance comparison.

An earlier wheel run and an earlier stress run timed out while build work was
also active. The final dedicated stress run and relocated wheel run passed with
unchanged timeout limits. Swift Build emitted seven ARCHS/VALID_ARCHS warnings in
the successful x86_64 cross-build; the actual x86_64 binary, runtime and archive
were verified independently.

Developer ID signing, notarization, hosted CI, public distribution, macOS 15
execution and physical Intel hardware acceptance were not performed here.
