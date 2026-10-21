# Tatara

## Language

- Write repository guidance, documentation, commit subjects/bodies, and source code comments in English.
- Keep user-facing strings localized; this rule does not replace translated UI copy.

## Shared guidance

- Keep this file concise, actionable, and durable. Store measurements, task history, version-specific findings, and temporary status in reports or issues.
- Keep contributor-wide conventions in repository guidance and update them when contracts change. Keep personal preferences and machine-specific details outside this file.

## Performance and responsiveness

- Reserve the main actor for keyboard/pointer input, state transitions, and bounded TermLoom presentation. Run subprocesses, file/database I/O, parsing, wrapping, and indexing on workers; `async` or `Task` alone does not establish that boundary.
- Update selection and input feedback immediately. Cancel obsolete reads and coalesce redundant work without arbitrary settling delays, debouncing, retries, or silent fallbacks.
- Preserve ownership across every suspension: repository, item, immutable revisions, file, viewport, and search generation must still match before publishing results or enabling review actions.
- An old document may remain as an identified preview while replacement loads or fails. It must not provide review anchors or search results for the new selection.
- Prepare immutable lookup data when its source changes. Keep cursor movement, scrolling, and view evaluation proportional to the viewport or indexed lookup, not document size. Reuse presentation across theme changes.
- Give caches explicit identity, invalidation, count/byte limits, and eviction. Never hold UI-shared locks across parsing, IPC, or I/O; preserve atomic persistence and account isolation.
- Measure the actual PR/file navigation burst, search, resize, or scrolling sequence in a Release PTY. Separate synchronous input, external/preparation work, and synchronized terminal output; report tail latency and cache/workload conditions. Tests and subprocess completion do not prove perceived responsiveness. See [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

## Architecture

- `TataraCore` owns portable, Sendable value types and source-coordinate invariants. It imports no TCA or UI framework.
- `TataraKit` owns TCA features and dependency clients. Live implementations are injected at the executable composition root.
- `TataraGitHub` implements the forge contract through `gh`. Do not add a separate token store, OAuth flow, or HTTP fallback.
- `TataraSystem` owns subprocess execution, configuration, and difftastic caching. Commands are executable/argument arrays, never shell command strings.
- `TataraPersistence` implements the SQLiteData cache behind `CacheClient`. Scope reads by account, host and repository; validate review writes against fresh remote state.
- `TataraTUI` owns TermLoom presentation. Keep AppKit and platform UI out of shared modules. macOS is the supported platform until the dependency graph can support another platform honestly.
- Preserve provider identity (forge, host, repository, number), native terminology, typed metadata and capabilities when adding a forge.
- Every diff compares immutable merge-base/head content. Keep rename provenance. A failure is visible; never substitute a two-dot diff or checkout the user's worktree.
- Inline review anchors are validated against the forge patch. Never infer source coordinates from difftastic's visual columns.
- Writes require a concrete preview, are tied to the reviewed head, and are never retried automatically.

## UI and localization

- Follow Vim motions and consistent pane vocabulary. Key bindings are data in `Keymap`; render help from the active bindings.
- Wheel and scrollbar input change only viewport offsets; preserve pane focus, PR/file selection and the Diff source cursor. Explicit selection/cursor movement reveals its target.
- Start with a dedicated, fully detailed PR selection screen. The review workspace has a short PR summary above a tall Files pane. Ctrl-p switches PRs through a cancellable quick picker; no compact/rich density mode. The picker opens in Normal mode with Vim navigation; / or i enters text input, and Esc leaves input before closing the picker.
- Tab and Shift-Tab cycle the panes on the active screen. Enter opens a PR into Files or a file into Diff; on folders it toggles expansion. Keep h/l local to the active pane.
- Wrap diff source by default; allow explicit horizontal scrolling when wrap is off. j/k move source lines, gj/gk move display lines, and Ctrl-f/Ctrl-b page content with its cursor even while Files retains focus.
- Published comments have independent focus identities and source-side placement. Gate mutations on fresh GitHub permissions, account, comment version and reviewed head; require a concrete preview for every write.
- Render Markdown only for prose and previews. Preserve literal diff source and review coordinates across wrapping, search and resize.
- Main item search uses forge query semantics; quick-picker text filters the loaded item list. File search reads immutable file contents. Combined diffs retain per-row file identity, and comment annotations never create review anchors.
- Inherit the terminal default background on ordinary surfaces so terminal transparency and blur remain effective. Use explicit fills for interaction highlights and controls.
- Use all four Catppuccin flavors and semantic palette roles. Preserve source content verbatim apart from terminal control sanitization.
- Preserve difftastic's changed-token ranges and syntax categories. Follow difftastic's directional ANSI colors and JSON-exposed emphasis: bold keywords/types/delimiters and italic comments, with no custom syntax colors, inferred word underlines or insertion/deletion background fills. Search and visual-selection highlights belong to Tatara's interaction layer.
- Narrow diffs show both removed and added source rows in a unified layout. Keep source identity independent of presentation row order; resizing must preserve the source cursor and review anchors.
- The Files tree has a `/` root that selects a combined diff of every changed file. Preserve per-file source identity and normal folder navigation.
- File rows show forge status, nonzero line-count changes and published file-comment counts with compact indentation. Preserve readable names and distinguish forge file changes from difftastic's structural change status.
- User-facing copy belongs in `SharedResources/Localizable.xcstrings`, with complete en, ko, ja, zh-Hans and zh-Hant entries.
- Run `swift Scripts/Tatara.swift localizations` after editing the catalog. The generated Swift table makes the CLI relocatable. Do not edit generated tables directly.
- Bootstrap/command diagnostics, tool names, API state identifiers and source-authored text may retain their original language.

## Development and release

- `Project.swift` and `Tuist/Package.swift` are authoritative. Regenerate after manifest/dependency changes. Do not edit generated projects.
- Use Swift 6 strict concurrency, TCA TestStore and Swift Testing. Verify a nonzero executed test count and actual PTY keyboard behavior.
- Use XcodeBuildMCP when available. The test scheme is `Tatara`.
- Run format, catalog, third-party notice and REUSE checks before release.
- Write project automation in Swift. `Scripts/Tatara.swift` is the command entry point; `Scripts/Smoke` owns the SwiftTerm PTY test helper.
- `Project.swift` owns the version. Release builds are signed command-line executables, notarized before publication, with corresponding source and notices.
- mise is the recommended binary installation path. Homebrew installs a formula, not a cask. The package manager owns updates.
