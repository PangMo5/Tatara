# Tatara

A terminal workspace for reading and reviewing pull requests, with
[difftastic](https://github.com/Wilfred/difftastic) for structural diffs,
Vim motions, and a pane-based review workflow.

![Tatara's Catppuccin Mocha workspace with a side-by-side difftastic review](docs/images/tatara.png)

Synthetic demo, rendered from an actual PTY capture.

Tatara currently supports **GitHub through `gh`**, including GitHub Enterprise.
It runs on macOS 15 or newer. GitLab and other forges can be added behind the same
client boundary while retaining their own terminology and capabilities.

## Try from source

Requires Xcode with Swift 6.3 or newer and [mise](https://mise.jdx.dev).

```sh
mise install
mise run generate
mise run build
DerivedData/Build/Products/Debug/tatara --demo

gh auth login
DerivedData/Build/Products/Debug/tatara --repo OWNER/REPO
```

Run without `--repo` inside a repository to use `gh repo view`'s repository
selection. `--host github.example.com --repo OWNER/REPO` selects an Enterprise
host; authenticate it first with `gh auth login --hostname github.example.com`.

## Binary installation

The first public release and Homebrew tap publication have **not happened yet**.
The release workflow prepares the following installation paths.

Recommended, after publication:

```sh
mise use -g github:PangMo5/Tatara
mise use -g aqua:cli/cli aqua:Wilfred/difftastic
gh auth login
tatara --repo OWNER/REPO
```

Homebrew, after publication:

```sh
brew install PangMo5/tap/tatara
```

Use `mise upgrade github:PangMo5/Tatara` or `brew upgrade tatara` for updates.
Release archives include the executable, AGPL license, dependency notices and a
corresponding-source reference. See [release setup](docs/RELEASING.md).

## Review workflow

- `j/k` or arrows select an item. `Enter`, `Tab`, `h/l`, or `1/2/3` change panes.
- `[` / `]` switch Overview, Diff, Discussion and Checks.
- `gg/G` jump to first/last; `Ctrl-d/Ctrl-u` move half a page.
- `/` filters loaded items; `n/N` move within the matches. `L` loads another page.
- `I` switches PRs and issues. `r` refreshes. `o` opens the original in a browser.
- `Space` marks the selected file reviewed for this PR's exact base/head revision.
- `c` starts an inline comment on a selected file. Choose LEFT/RIGHT and a source
  line from the diff. `R` opens the review summary; Preview shows all pending
  comments before Submit. Issues support ordinary comments.
- `T` cycles Catppuccin flavors. `?` shows the current key bindings. `q` quits.

Inside review editors, use the native text editing keys and Tab to move between
fields/buttons. Esc returns to the workspace. Drafts and reviewed marks are kept
only for the lifetime of the process. A changed head requires a refreshed review.

## Configuration

Create `$XDG_CONFIG_HOME/tatara/config.toml` (default `~/.config/tatara/config.toml`):

```toml
theme = "mocha" # latte, frappe, macchiato, mocha
language = "ko" # en, ko, ja, zh-Hans, zh-Hant

[keys]
quit = ["Q"]
```

`--theme`, `--language` and `--config` override the defaults. Conflicting bindings
are errors. `--no-color`, `--ascii` and `--accessible` are provided by SwiftTUI.
The complete locale policy is in [LOCALIZATION.md](docs/LOCALIZATION.md).

## Development

Tuist owns the project graph. TCA owns application state and effects. SwiftTUI
owns terminal layout, input and rendering. Swift Subprocess runs `gh` and `difft`
with explicit arguments and cancellation. TOML configures user preferences.

```sh
mise run test
mise run format
python3 Scripts/generate-localizations.py --check
python3 Scripts/generate-notices.py --check
uvx --from 'reuse[charset-normalizer]' reuse lint
uv run --with pyte python Scripts/test-pty.py DerivedData/Build/Products/Debug/tatara
```

See [architecture and initial boundaries](docs/ARCHITECTURE.md),
[contributing](CONTRIBUTING.md) and [third-party notices](THIRD_PARTY_NOTICES.md).

## License

[AGPL-3.0-only](LICENSE). Included dependencies retain their licenses;
see [third-party notices](THIRD_PARTY_NOTICES.md).
