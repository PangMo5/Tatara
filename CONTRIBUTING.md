# Contributing

Use the pinned mise tools and Xcode with Swift 6.3 or newer. Generate the workspace
with `mise run generate`; build and test the `Tatara` scheme. Source directories
and Tuist manifests are authoritative.

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
