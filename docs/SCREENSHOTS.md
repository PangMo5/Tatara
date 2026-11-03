# Reproducing the README screenshot

The README image contains synthetic demo data from the Release executable's real
PTY output. `Scripts/Smoke` renders the emulator cells to a PNG using
[`images/readme-terminal.json`](images/readme-terminal.json): Maple Mono NF KR
12pt, the Catppuccin Mocha foreground/background and 16 ANSI colors, four extra
points of line height, and the configured contextual/stylistic font features.
Box borders and block elements are rendered as pixel-aligned cell graphics, so
extra line height does not introduce seams. Equal-style text runs are shaped
together; ANSI palette indices are resolved through the terminal's active palette
rather than a hard-coded default table.

The exact four Maple Mono NF KR faces named in the profile must already be
installed on the Mac performing the capture. The command does not install fonts,
and another Maple Mono variant is not silently substituted. Run from the
repository root:

```sh
mise exec -- swift Scripts/Tatara.swift build Release
mise exec -- swift Scripts/Tatara.swift readme-screenshot
```

The command validates the PR selection and review workflow and atomically replaces
`docs/images/tatara.png` with the combined review view. Intermediate PNG, ANSI and
text captures are written under `.artifacts/swift-pty/reading-workspace/`.
The workflow checks the rendered PNG for continuous horizontal and vertical
border pixels, including corner joins. Missing fonts, invalid profiles and border
gaps are explicit errors. Fonts are not bundled.

The PNG uses a solid Mocha background and 2× rendering. Desktop transparency,
wallpaper blur, compositor effects and animated cursor shaders are not captured.
This avoids publishing surrounding desktop content. The result represents the
terminal cell content and its font/palette, not a native window screenshot or a
performance measurement.

Other PTY scenarios use the standard helper appearance unless
`--screenshot-style PATH` is supplied. Changing a screenshot style does not alter
Tatara's runtime theme, terminal preferences, review state or test coordinates.
