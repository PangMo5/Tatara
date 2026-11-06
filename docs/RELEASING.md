# Releasing Tatara

Tatara currently installs from source. No binary release has been published, and
Homebrew is not supported. The workflow below prepares GitHub release archives;
its signing, notarization and consumer-installation paths remain unverified.

The version is `TataraVersion.current` in `TataraCore/Sources/TataraVersion.swift`;
`CHANGELOG.md` must have the same version heading. SwiftPM owns the build graph;
build products and local secrets are ignored. The executable embeds its version
as Swift data and does not require an Info.plist or an application resource bundle.
The Swift 6.4.2 build requires `libswiftCompatibilitySpan.dylib` for back deployment;
the build script copies it with Apple's `swift-stdlib-tool` into the same directory
as `tatara`. Local installation and release archives preserve both files.

## One-time setup

Configure main-branch rules and add these repository secrets before a release:

| Secret | Purpose |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Exported Developer ID Application signing certificate |
| `DEVELOPER_ID_P12_PASSWORD` | Certificate password |
| `KEYCHAIN_PASSWORD` | Temporary CI keychain password |
| `AC_API_KEY_ID` | App Store Connect notarization key ID |
| `AC_API_ISSUER_ID` | App Store Connect issuer ID |
| `AC_API_KEY_P8` | App Store Connect private key |

CI selects Xcode 27.2 on `xcode-27` and validates Swift 6.4.2 and the macOS 27.2
SDK before resolving dependencies. The runner's Xcode app build number is logged
for diagnosis; matching compiler/SDK versions can be tested even when the hosted
app is still the release candidate. Binary release validation and `release-build`
additionally require the stable Xcode app build 27B52 before any signing work.
A local successful build does not establish hosted CI.

## Release process

1. Update the authoritative version and changelog. Run CI checks locally,
   including a nonzero test count, PTY runtime, catalogs, formatting and REUSE.
2. Merge the candidate to main. Push an immutable matching `vX.Y.Z` tag.
3. The workflow repeats CI, checks tag/version agreement and main ancestry,
   builds both architectures with SwiftPM's `--arch`, signs each executable and
   its compatibility runtime with hardened runtime and timestamps, and requires
   an Accepted notarization result for each archive.
4. It publishes architecture-specific archives, SHA256SUMS and a source archive
   to GitHub Releases, then downloads and verifies the public checksums.

`release-build` resolves both lockfiles without allowing changes and builds the
requested `ARCH` (`arm64` or `x86_64`) for macOS 15. The build queries
`swift build --show-bin-path` with that configuration and architecture, then stages
the executable and compatibility runtime in
`.artifacts/products/release-ARCH`. Signing, notarization and packaging consume
that prepared directory; SwiftPM's managed output directory is never modified.
Do not hard-code SwiftPM's output directory, which varies by build engine.
For an ad-hoc cross-architecture build without release credentials, use
`ARCH=x86_64 mise exec -- swift Scripts/Tatara.swift build Release` (or `arm64`).
Architecture selection must preserve each dependency's declared deployment target;
do not force the root macOS version onto dependencies through a versioned triple.
Keep `macOSDeploymentTarget` and `macOSSDKVersion` in `Package.swift` aligned with
the toolchain checks. Every build verifies the final Mach-O deployment/SDK fields;
compile-time SDK paths alone do not establish correct artifact metadata.

The workflow does not create or update a Homebrew formula. A future binary
installation command may be documented only after its artifacts are published
and a clean consumer installation has been verified. mise's GitHub backend is a
candidate consumer path, not an installation method available before publication.

Bare executables cannot carry a stapled notarization ticket. The workflow submits
a ZIP containing each signed executable and its signed Swift compatibility
runtime to Apple's notary service, then includes those same files in the
distributable tarball. Validate Gatekeeper's
online assessment on a clean Mac before announcing the first binary release;
local ad-hoc builds do not establish this distribution path.

The workflow never replaces existing public release assets. If a later step
fails after publication, inspect public state and resume only that step. Do not
rerun publication blindly or overwrite an existing tag.

## Independent consumer checks

- Download the public assets and verify SHA256SUMS.
- Inspect both architectures with `lipo`, signatures with `codesign`, and the
  notarization outcome. Confirm the only non-system dynamic library is the
  included, signed `libswiftCompatibilitySpan.dylib`, with the target architecture.
- Keep the executable and runtime in the same directory. Verify dyld loads the
  runtime from that directory without consulting an installed Xcode toolchain.
- After publication, install into an isolated mise data directory and verify
  `tatara --version`, localized UI and actual `gh`/`difft` execution.
- Confirm corresponding source and all notices remain available for the release.

Signing, notarization, hosted CI, public downloads, clean-Mac Gatekeeper and an
actual consumer installation require separate evidence from local build and
packaging checks.
