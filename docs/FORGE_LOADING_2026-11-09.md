# Forge loading animation — November 9, 2026

Tatara now presents a hammer striking an anvil during initial loading and empty
content preparation. Hammer poses and small sparks use semantic Catppuccin roles;
ordinary surfaces inherit the terminal background. ASCII and no-color modes keep
corresponding representations.

The scene is a TUI-only value presentation. Its eight poses use monotonic elapsed
time at 150 ms per pose. TermLoom's existing periodic-redraw capability is enabled
only while a visible loading activity is pending. No animation actions, sleeps or
minimum display duration are added to the reducer or data-loading paths. The
native idle loop resumes once work completes, and reduced-motion, stable-output
and accessibility flags hold a static pose.

Existing identified previews remain visible during PR/file replacement. The
loading artwork creates no document rows, search matches or review anchors.
Initial loading is identified by absent PR selection/detail, independent of an
empty placeholder document that resizing may prepare. A regression test covers
that transition; failures remain visible instead of being replaced by artwork.

## Verification

- 130 Swift Testing tests passed, including all four themes, inherited background,
  ASCII/no-color, preview/cursor/generation preservation, resize placeholders and
  failure visibility.
- Release PTY loading checks passed for bootstrap and PR-list loading, cancellation,
  reduced motion, stable output, accessibility, ASCII/no-color, resizing and
  keyboard input. A FIFO holds fixture responses; completion releases it without
  changing production timing. The test verifies no redraws continue while idle.
- Release navigation checks passed for both the previous installed executable and
  the updated executable, with animations enabled in the helper.
- Release SDK/deployment metadata and local ad-hoc signing remain validated by the
  build script. Formatting, catalog, notices and REUSE checks passed.

## Release PTY measurements

Both comparison runs used 320×64 cells, 100 fixture PRs, 120 files, an approximately
2.5 MB overview and eight 21,000-character source lines. They ran sequentially with
identical `--navigation`, `--wide-lines`, `--burst`, `--dense-navigation`,
`--loading-burst`, `--directional-burst` and `--animated` settings. Each run has a
fresh fixture data/cache directory and warms its first two PRs/files before the
selection samples. No compiler, CPU sampler or preview recorder ran alongside
these timing samples; unrelated host workload was uncontrolled.

Synchronous `Store.send` work is recorded separately in `input.tsv` (588 inputs
per run): before p95/max 0.85/6.58 ms; after 0.51/5.82 ms. End-to-end feedback below
ends at the synchronized PTY frame containing the expected selection. It includes
emulator parsing and is not a measurement of compositor paint or terminal-write
CPU time alone. Each run contains 120 navigation observations.

| Feedback stage | Before p95 / max (ms) | After p95 / max (ms) |
| --- | --- | --- |
| PR burst, 25 ms spacing | 27.99 / 27.99 | 3.66 / 3.66 |
| File burst, 25 ms spacing | 9.52 / 9.52 | 5.72 / 5.72 |
| PR selection in flight | 2.32 / 2.56 | 2.60 / 12.57 |
| File selection in flight | 8.09 / 9.91 | 8.00 / 8.18 |

Directional bursts measure the last input through its reflected selection. Each
cell below is a single observed tail, not a percentile estimate.

| Burst | Before tail (ms) | After tail (ms) |
| --- | --- | --- |
| PR × 8 | 4.98 | 5.09 |
| PR × 32 | 7.60 | 9.41 |
| PR × 64 | 7.58 | 8.38 |
| FILE × 8 | 8.10 | 25.25 |
| FILE × 32 | 5.24 | 5.02 |
| FILE × 64 | 4.90 | 6.09 |

External/preparation readiness is separate from input feedback: the initial PR
warm-up completed in 2108/2129 ms before/after; initial file readiness was
5201/4186 ms. These include deliberately delayed synthetic providers.

The held-response loading test measured 24 query-entry samples at 90×28 cells,
covering animated Unicode and ASCII/no-color: median 0.50 ms, p95
0.78 ms, maximum 3.13 ms. Screenshot capture is outside those input samples.

This single before/after pair establishes these observed behaviors, not a general
performance improvement or real-network latency claim. No forge writes occur.

Baseline SHA-256: `62c5d9b5a224550855afb27bbd3fd91114a50144cbc575a54d24a5521d22a02b`

Updated SHA-256: `7f71bc1dc07cf96d88f5eecd3def006d642db08e586240314bb7a09fcd60f35c`

Raw reports: `.artifacts/swift-pty/navigation-forge-before/`,
`.artifacts/swift-pty/navigation-forge-after/`, and
`.artifacts/swift-pty/loading/`. The local GIF preview is assembled from actual
completed terminal-cell screenshots and is not a timing artifact.


## Visual refinement

The revised artwork replaces disconnected punctuation with connected steel hammer
heads, wooden handles, glowing workpieces and shaded anvils with distinct horns,
waists and feet. Impact poses emit sparks. The centered scene occupies 34 × 14
terminal cells; the diff-preview scene uses an independently rasterized 18 × 7
version with the same swing angles. A narrow pane retains inline feedback instead
of squeezing the scene into unreadable dots. The preview reserves a right gutter
only alongside the scene; source rows, cursor ownership and review coordinates do
not change. Current source search continues to use the footer indicator.

Immutable sprites use half blocks with semantic foreground/background colors.
Only occupied artwork pixels use explicit fills; surrounding surfaces keep the
terminal background. Monochrome mode preserves the entire silhouette without
color-dependent half cells. ASCII mode uses ordinary text characters.

Verification of the refined Release executable:

- 137 Swift Testing tests passed, including all four palettes, ASCII/no-color,
  inherited background, narrow previews and existing ownership regressions.
- Seven held-response PTY variants passed: bootstrap, PR list, diff preparation,
  reduced motion, stable output, accessibility and ASCII/no-color. They exercise
  cancellation, input, resizing, completion and zero periodic redraws while idle.
- During loading, 36 query-entry/tab-focus observations at 90 × 28 / 176 × 40 cells
  had median/p95/max terminal-frame feedback of 0.58/1.94/2.13 ms. Screenshot
  capture is outside these samples.
- A Release navigation run used the same 320 × 64, 100-PR, 120-file, wide-source
  fixture and animated burst flags described above. It produced 120 observations
  and 588 synchronous input samples (p95/max 0.32/1.67 ms).
  PR/file in-flight feedback p95 was 2.16/8.69 ms and maxima were 2.42/21.15 ms.
  The final visible tails of 8/32/64-key directional bursts were
  5.08/4.99/5.16 ms for PRs and 3.26/3.16/3.26 ms for files. Initial provider
  readiness was 2093 ms for PRs and 4242 ms for files, including fixture delays.
  No compiler, CPU sampler or preview recorder ran alongside these samples;
  unrelated host workload was uncontrolled. These are observations, not a
  comparative speed claim.
- Formatting, catalog, third-party notices, REUSE and SDK/deployment checks passed.

Refined executable SHA-256:
`7fb7802a1cc536f778479db63a0399aa559abe6344d3beac74f6eb6f25dfb662`

Raw refinement evidence: `.artifacts/swift-pty/navigation-forge-polish/` and the
latest `.artifacts/swift-pty/loading/` captures. The large and compact local GIFs
are cropped from the completed Release terminal screenshots at their recorded
capture intervals; they are visual previews, not performance recordings.
