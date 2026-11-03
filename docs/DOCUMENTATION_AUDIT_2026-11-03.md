# Documentation and screenshot audit — November 3, 2026

This audit compares current contributor/user guidance with source, CLI help,
configuration decoding, workflow commands and the remote repository state. Dated
investigation reports retain their original measurements and now explicitly
identify their dependency/UI/command descriptions as historical.

## Corrected discrepancies

| Area | Finding | Current result |
| --- | --- | --- |
| README image | Menlo 14pt, emulator default black and a hard-coded ANSI table did not match the configured terminal. | Maple Mono NF KR 12pt, Mocha foreground/background and all 16 ANSI colors match the terminal profile. The PNG is rendered at 2× with contextual font shaping and dim text. |
| Screenshot reproduction | No committed appearance profile or reproduction command. | `readme-screenshot` uses `docs/images/readme-terminal.json`; missing fonts fail explicitly. Desktop blur/transparency are excluded from the PNG. |
| Binary installation | Future Homebrew and mise binary commands were presented alongside current installation instructions. | Source installation is the current path. GitHub has no binary releases and the tap has no Tatara formula. README states these limits. |
| Release automation | The unpublished Homebrew formula generator and tap update remained wired into a release. | Formula generation, formula assets, tap mutation, its dispatch commands and tap-token requirements are removed together. GitHub archive/signing/notarization preparation remains. |
| Changelog | The current version still described SwiftTUI and implied both package-manager paths. | It describes TermLoom and labels the source version independently from an actual published binary release. |
| Architecture | Thread resolution was listed as future work even though it is implemented. | Fresh-permission, previewed resolution/reopening is documented. |
| Architecture | Snapshot acquisition described only one selected file. | The per-file and combined folder/root pipelines are described separately. |
| Editor limitations | “Characterwise editing” could be read as excluding the implemented text editor. | The limitation now names characterwise diff visual selection, while documenting native review text editing. |
| Configuration | The example omitted three supported settings and described only one multi-key motion. | `files_view`, `sidebar_width`, `wrap` and current key-override semantics are included. |
| Localization | It referred to unrelated projects and unshipped Homebrew symlinks. | The guide describes Tatara's own locales and relocatable source installation. |
| Historical links | A renderer-comparison link targeted a prototype directory absent from the repository. | The prose explicitly identifies the archived, unshipped prototype. All local Markdown targets resolve. |
| Security reporting | The policy referred to private vulnerability reporting, but GitHub had it disabled. | Private vulnerability reporting is enabled and the policy links directly to the reporting page. |

## Verification

- The optimized smoke helper built with the selected Xcode toolchain.
- The full PR selection/quick-picker/review PTY scenario passed with both the
  README profile and the standard helper appearance. The missing-font case
  failed with the intended explicit diagnostic and no font substitution.
- The profile matches the configured foreground/background and all 16 ANSI
  entries. The PNG is 2600 × 1984 pixels and was visually inspected.
- All local Markdown targets resolve. Every workflow's Swift automation command
  is registered by the command dispatcher. The configuration example matches the
  current TOML decoder fields and key-override contract.
- Version and release-note generation pass; generated release notes contain no
  Homebrew install instruction. Formatting, catalogs, notices, REUSE and whitespace
  checks pass.
- GitHub Releases returned an empty list; the Tatara formula path returned 404.
  GitHub confirmed private vulnerability reporting is enabled after the change.
- Current CLI options and key descriptions were compared with `--help`, `Keymap`
  and their reducer/renderer paths. The documented 3,000-file forge limit agrees
  with [GitHub's file-list documentation](https://docs.github.com/en/rest/pulls/pulls#list-pull-requests-files).

No production app behavior or dependencies changed in this audit. It does not
establish signed/notarized distribution, clean-Mac installation, a live forge
write, native-language editorial review or macOS window-compositor fidelity.
The hosted runner's Xcode 27.2 RC build remains separate from the locally
validated stable 27B52 toolchain; its CI failure is still visible rather than
being described as a successful hosted build.
