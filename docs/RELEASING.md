# Releasing Tatara

This repository prepares releases but has not published its first release.
The version is `appVersion` in `Project.swift`; `CHANGELOG.md` must have the same
version heading. Generated projects, build products and local secrets are ignored.

## One-time setup

The source repository is public; a signed and notarized binary release has not
been published. Configure main-branch rules and Actions access to the existing
`PangMo5/homebrew-tap` repository. Add these repository secrets:

| Secret | Purpose |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Exported Developer ID Application signing certificate |
| `DEVELOPER_ID_P12_PASSWORD` | Certificate password |
| `KEYCHAIN_PASSWORD` | Temporary CI keychain password |
| `AC_API_KEY_ID` | App Store Connect notarization key ID |
| `AC_API_ISSUER_ID` | App Store Connect issuer ID |
| `AC_API_KEY_P8` | App Store Connect private key |
| `HOMEBREW_TAP_TOKEN` | Token permitted to update the Homebrew tap |

CI selects Xcode 27.2 on `xcode-27` and validates Swift 6.4.2 and the macOS 27.2
SDK before resolving dependencies. Check the current runner image when updating
this selection; a stale runner image fails validation explicitly. The local successful build
does not establish a successful hosted CI run.

## Release process

1. Update the authoritative version and changelog. Run CI checks locally,
   including a nonzero test count, PTY runtime, catalogs, formatting and REUSE.
2. Merge the candidate to main. Push an immutable matching `vX.Y.Z` tag.
3. The workflow repeats CI, checks tag/version agreement and main ancestry, builds
   both architectures, signs the executables with hardened runtime and timestamps,
   and requires an Accepted notarization result.
4. Publish architecture-specific archives, SHA256SUMS, a source archive and a
   generated Homebrew formula. Download the public archives and verify checksums.
5. Update the tap. mise's GitHub backend discovers the architecture-specific
   archives directly; no separate mise plugin or registry entry is required.

Bare executables cannot carry a stapled notarization ticket. The workflow submits
a ZIP containing each signed executable to Apple's notary service, then includes
that same signed executable in the distributable tarball. Validate Gatekeeper's
online assessment on a clean Mac as part of the first public release; local
ad-hoc builds do not prove this distribution path.

The workflow never replaces existing public release assets. If a later step
fails after publication, inspect public state and resume only that step; do not
rerun publication blindly or overwrite an existing tag.

## Independent consumer checks

- Download the public assets and verify SHA256SUMS.
- Inspect both architectures with `lipo`, signatures with `codesign`, and the
  notarization outcome. Confirm no non-system dynamic library is required.
- Install into an isolated mise data directory and verify `tatara --version`,
  localized UI and actual `gh`/`difft` execution.
- Install the generated formula on the matching Mac architecture, run its test,
  and verify the installed version and artifact hash.
- Confirm corresponding source and all notices remain available for the release.

Signing, notarization, hosted CI, public downloads, clean-Mac Gatekeeper, actual
mise release installation and actual Homebrew installation are separate evidence
from the local build and local packaging test.
