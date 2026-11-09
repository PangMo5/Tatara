# Contributing

Use the pinned mise tools and Xcode 27.2 (Swift 6.4.2 and macOS 27.2 SDK).
Run `mise run toolchain` to validate the selected compiler and SDK. `DEVELOPER_DIR`
can override the local Xcode installation path. Resolve packages with
`mise run resolve`, build with `mise run build` and test with `mise run test`.
`Package.swift`, `Package.resolved` and source directories are authoritative;
there is no generated Xcode project. Open `Package.swift` in Xcode for IDE support.
Direct `swift build`, `swift test` and `swift run tatara` work through `mise exec`.

TermLoom core and TextArea are a local source package in `ThirdParty/TermLoom`.
Preserve its provenance and license when updating it. Runtime changes belong in
tracked source and must not be applied to SwiftPM's dependency caches.

Write commit subjects, commit bodies and source code comments in English.
User-facing strings remain localized in the String Catalog.

Keep domain values portable, reducers deterministic, and external effects behind
dependency clients. Add focused Swift Testing/TestStore coverage for observable
behavior, particularly cancellation, pagination, source anchors and write intent.
Run the PTY test script when changing input or rendering.

User-facing strings belong in the five-locale String Catalog. Regenerate its Swift
table and validate it. Dependency updates also require regenerated notices. Run
format, tests, localization validation and REUSE lint before submitting a PR.

Contributions are licensed under AGPL-3.0-only. Keep third-party notices intact and
use minimal synthetic fixtures. Do not include credentials or private review data
in bug reports, logs or fixtures.

Keep public history free of credentials, private review data, employer-specific
workspace names and personal absolute paths. Use synthetic fixtures and portable
paths. CI scans the full fetched history with Gitleaks.

## Version control

Use Jujutsu (`jj`) with a colocated Git repository. Existing Git history and
GitHub interoperability are preserved; `.jj/` is local workspace metadata.

```sh
jj git clone --colocate https://github.com/PangMo5/Tatara.git
# For an existing Git checkout instead:
jj git init --colocate
```

Start work with `jj new main`, inspect changes with `jj status` and `jj diff`,
and record them with `jj commit -m "Describe the change"`. Create task bookmarks
under `pangmo5/`, for example `jj bookmark create pangmo5/update-tools -r @-`.
Push the concrete bookmark with `jj git push --remote origin --bookmark NAME`.
Use `jj git fetch --remote origin` to refresh remote state before integration.
The existing `main` bookmark remains the default integration branch. Do not
rewrite published history or rename existing bookmarks as part of routine updates.

SwiftFormat follows the upstream Airbnb configuration linked in `.swiftformat`,
with Swift 6 language mode, SPDX headers and generated/vendor exclusions.
Guard-like conditional assertions are preserved: SwiftFormat 0.64.5 otherwise
changes valid parameterized test cases into failing preconditions.
Run `mise run format` and `mise exec -- swift Scripts/Tatara.swift lint` before
pushing. Both commands ignore the formatter cache so local checks match clean CI.
Update the upstream configuration and its source commit together.
