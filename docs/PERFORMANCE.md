# Measuring responsiveness

Measure a Release executable, using the same terminal dimensions and workload
for both builds. Run comparisons sequentially with other builds and profilers
idle. Keep the older executable until the comparison is complete.

```sh
swift Scripts/Tatara.swift smoke PATH_TO_BINARY --profile current --columns 320 --rows 64
```

This uses an isolated cache and synthetic `gh`/`difft` processes: a roughly
2.5 MB PR paragraph, delayed detail loading and a 25,000-line structured diff. It
switches focus while those reads and document preparation are in flight, then
measures main-pane half-page scrolling. No forge writes occur.

Pane focus is different from selecting another PR or file. To measure `j/k`
selection while documents are being replaced, use:

```sh
swift Scripts/Tatara.swift smoke PATH_TO_BINARY --navigation current --wide-lines --burst
swift Scripts/Tatara.swift smoke PATH_TO_BINARY --live-navigation PATH_TO_REPOSITORY --label current
```

`--navigation` warms two PRs and files, measures settled replacements, then
selects while preparation can still be in flight. `--wide-lines` uses eight
21,000-character source rows to exercise horizontal clipping. `--burst` adds
25 ms and 120 ms keyboard replay from a separate input producer, without waiting
for each frame. Its burst result measures the final help key's response after
the replay, separately from individual `j/k` latency. There is no artificial
sleep after the final key. Raw samples and stage summaries are in
`navigation.json`, beside the frame diagnostics. `*-warmup-ready` records the
same key through final document readiness, separately from immediate selection.
The helper also measures diff cursor movement and fixture content search. Fixture
request counts and `requests.log` distinguish cache reuse from extra external work.

For search and review behavior, run:

```sh
swift Scripts/Tatara.swift smoke PATH_TO_BINARY --search-review
```

This checks GitHub query submission, label toggles, immutable file-content search,
combined folder diffs, existing and outdated comments, regex highlighting and n/N,
all four palettes, and an inline range editor/preview across terminal resizes.
It uses demo fixtures and performs no forge writes. `--features`, `--editors`, and
`--workspace` cover the remaining navigation, editor, mouse, cache and popup flows.

The live navigation mode uses the first two open PRs and first two files,
with no forge writes. Confirm that these are the items that reproduce a report;
a fast result on other files does not disprove a reported pause. Also verify
the loaded executable's UUID: installing a new binary does not replace an
already-running process.

Results live in `.artifacts/swift-pty/profile-current/`:

- `latency.json`: key-send to expected rendered terminal state, including the
  terminal emulator's parsing time; median, p95, maximum, sample count, screen
  dimensions, OS and executable SHA-256.
- `diagnostics.tsv`: optional legacy SwiftTUI per-frame diagnostics when comparing
  an archived SwiftTUI executable. TermLoom does not emit this file.
- `frames-summary.json`: legacy summaries of resolve, raster, pipeline, main-actor and
  input-to-commit timings. These describe runtime stages, not physical display latency.
- `input.tsv`: synchronous `Store.send` duration for navigation input, written on
  a separate actor when `TATARA_INPUT_TRACE` is enabled. It includes reducer and
  synchronous cancellation work but not an awaited frame or network request.

The PTY reader checks state as bytes arrive, after the terminal's synchronized
output frame closes. It does not add a fixed 20 ms wait to every measurement.
The terminal emulator observes output bytes; this does
not measure the window compositor, display refresh or physical trackpad feel.

For CPU stacks, repeat separately with `--sample`. This produces
`cpu.sample.txt` through macOS `sample`; attaching a sampler perturbs execution,
so keep that run separate from the latency comparison. No elevated privileges
are required for the child process created by the test.

To inspect a real repository without publishing anything:

```sh
swift Scripts/Tatara.swift smoke PATH_TO_BINARY --live PATH_TO_REPOSITORY --item PR_NUMBER --columns 320 --rows 64
```

Real API timings vary and may hit the persistent cache. Treat this as runtime
verification, not a controlled before/after benchmark. Captures can contain
private source text; `.artifacts` is ignored by Git.

Current TermLoom runs use `TATARA_INPUT_TRACE` for reducer timing and the PTY's
synchronized output timestamps for visible completion. Use `--no-diagnostics`
for timing runs without tracing. `SWIFTTUI_DIAGNOSTICS` applies only to archived
SwiftTUI executables; it is not a TermLoom setting.

The functional `--workspace` case also checks cold-to-warm process reuse. Both
processes explicitly open the same initial file and wait for its path, source
content and completed Ready frame before filtering; the filtered target must
also finish before navigation continues. The initial cold snapshot is held by a
latched, per-request FIFO gate until the helper releases it. This makes the
readiness requirement explicit without a settling timer. Canceled reads that
never completed are not assumed to have populated persistent cache entries.

The helper preserves `requests.log`, `requests-cold.log` and `requests-warm.log`
under its artifact directory, including on failure. CI includes the hidden
`.artifacts` directory in the validation upload. These are synthetic fixture
requests; the gate is confined to the functional case and is not a performance
measurement or production-cache behavior.

The helper preserves mise's own data/cache directories while isolating Tatara's
XDG state. Comparisons across ANSI and structured-renderer versions must use the
matching helper fixture format; their payload sizes are not identical workloads.

Dated findings and before/after evidence belong in audit reports rather than
repository-wide agent instructions. See the [September 8 audit](PERFORMANCE_AUDIT_2026-09-08.md)
for the historical SwiftTUI audit's scope, workload and limitations.

When comparing archived SwiftTUI traces, `input.tsv` includes `frame_started_ms`
on a compatible monotonic time base. Legacy `pipeline_ms` and
`main_actor_blocked_ms` do not describe TermLoom and must not be used as its frame
or UI-thread timings. Report the active binary hash and renderer explicitly.

See the [September 8 isolation experiments](PERFORMANCE_ISOLATION_2026-09-08.md)
for component removals, minimal-state controls, clock alignment, and phase timing.

Add `--cold-navigation` to a fixture `--navigation` run to measure twenty j/k
selections before the initial PR detail and file diff reads can finish. Inspect
the recorded status for each `pr-cold`/`file-cold` sample; selection feedback and
remote completion are different timings.

To measure continuous selection through uncached items, without waiting for each
frame, run:

```sh
swift Scripts/Tatara.swift smoke PATH_TO_BINARY --navigation loading-burst --loading-burst --dense-navigation --directional-burst --columns 104 --rows 56
```

The dense fixture has 100 PRs and 120 files. Directional replay sends 8, 32, then
64 `j` inputs at a nominal 25 ms interval, checks that every input contributes to
the final selected index, and resets with `gg` between runs. It records selection
at each completed synchronized output frame, initial/final loading status, replay
duration, and final-key-to-final-selection latency. Inspect gaps between selection
changes as well as the final latency: a responsive help key after a burst does
not establish continuous selection feedback during that burst.

Without `--directional-burst`, `--loading-burst` alternates `j/k` and measures the
final help key. Directional replay requires the dense synthetic fixture; it does
not assume real PR numbers or file names are consecutive. These measurements
include PTY parsing, but exclude the terminal window compositor and display.


## Wheel reversal under continuous input

Run `Scripts/Smoke/.build/release/tatara-smoke BINARY --wheel-reversal LABEL --columns 320 --rows 64`
to replay downward and upward wheel input without waiting for intermediate frames.
The writer runs independently of terminal parsing. `reversal.json` records actual input
reversal time, completed frame offsets, old-direction frames emitted after reversal,
first reversed-frame latency and the tail after the final input. Compare the same
binary workload, terminal size and input cadence; final scroll position alone does not
establish prompt reversal. See [the reversal investigation](SCROLL_REVERSAL_2026-09-11.md).
