# Tatara

## Language

- Write commit subjects, commit bodies and source code comments in English.
- Keep user-facing strings localized; this rule does not replace translated UI copy.

## Architecture

- `TataraCore` owns portable, Sendable value types and source-coordinate invariants. It imports no TCA or UI framework.
- `TataraKit` owns TCA features and dependency clients. Live implementations are injected at the executable composition root.
- `TataraGitHub` implements the forge contract through `gh`. Do not add a separate token store, OAuth flow, or HTTP fallback.
- `TataraSystem` owns subprocess execution, configuration, and difftastic caching. Commands are executable/argument arrays, never shell command strings.
- `TataraTUI` owns SwiftTUI presentation. Keep AppKit and platform UI out of shared modules. macOS is the supported platform until the dependency graph can support another platform honestly.
- Preserve provider identity (forge, host, repository, number), native terminology, typed metadata and capabilities when adding a forge.
- Every diff compares immutable merge-base/head content. Keep rename provenance. A failure is visible; never substitute a two-dot diff or checkout the user's worktree.
- Inline review anchors are validated against the forge patch. Never infer source coordinates from difftastic's visual columns.
- Cancel obsolete read effects and reject stale generations. Writes require a concrete preview, are tied to the reviewed head, and are never retried automatically.

## UI and localization

- Follow Vim motions and consistent pane vocabulary. Key bindings are data in `Keymap`; render help from the active bindings.
- Use all four Catppuccin flavors and semantic palette roles. Preserve source content verbatim apart from terminal control sanitization.
- User-facing copy belongs in `SharedResources/Localizable.xcstrings`, with complete en, ko, ja, zh-Hans and zh-Hant entries.
- Run `python3 Scripts/generate-localizations.py` after editing the catalog. The generated Swift table makes the CLI relocatable. Do not edit generated tables directly.
- Bootstrap/command diagnostics, tool names, API state identifiers and source-authored text may retain their original language.

## Development and release

- `Project.swift` and `Tuist/Package.swift` are authoritative. Regenerate after manifest/dependency changes. Do not edit generated projects.
- Use Swift 6 strict concurrency, TCA TestStore and Swift Testing. Verify a nonzero executed test count and actual PTY keyboard behavior.
- Use XcodeBuildMCP when available. The test scheme is `Tatara`.
- Run format, catalog, third-party notice and REUSE checks before release.
- `Project.swift` owns the version. Release builds are signed command-line executables, notarized before publication, with corresponding source and notices.
- mise is the recommended binary installation path. Homebrew installs a formula, not a cask. The package manager owns updates.
