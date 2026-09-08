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
`navigation.json`, beside the frame diagnostics.

The live navigation mode uses the first two open PRs and first two files,
with no forge writes. Confirm that these are the items that reproduce a report;
a fast result on other files does not disprove a reported pause. Also verify
the loaded executable's UUID: installing a new binary does not replace an
already-running process.

Results live in `.artifacts/swift-pty/profile-current/`:

- `latency.json`: key-send to expected rendered terminal state, including the
  terminal emulator's parsing time; median, p95, maximum, sample count, screen
  dimensions, OS and executable SHA-256.
- `diagnostics.tsv`: SwiftTUI's per-frame pipeline timings and damaged rows.
- `frames-summary.json`: summaries of resolve, raster, pipeline, main-actor and
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

For an interactive session, set `SWIFTTUI_DIAGNOSTICS` to a writable TSV file
path before launching Tatara. The runtime records each frame until the process
exits. This can capture an interaction that the synthetic workload does not reproduce.

The helper preserves mise's own data/cache directories while isolating Tatara's
XDG state. Comparisons across ANSI and structured-renderer versions must use the
matching helper fixture format; their payload sizes are not identical workloads.

The September 7 investigation separated synchronous input handling from the
frame pipeline. In the sampled live repository, `Store.send` had a median of
0.251 ms and maximum of 1.19 ms, while an observed selection took up to 122.6 ms.
This rules out synchronous reducer work as the dominant delay in that run.
It does not identify every source of the remaining arrival-to-frame interval.
SwiftTUI queues input while an asynchronous frame is being acquired, and its
pipeline timings do not include the entire event-to-presentation lifetime.

The application now avoids whole-document ANSI decoding, reuses structured
immutable diffs, promotes disk hits into memory, and waits for selection settling
only on a diff cache miss. These changes remove repeated work; they do not prove
that every rapid-navigation pause is resolved. A temporary SwiftTUI color-storage
experiment reduced internal raster time but only modestly changed input latency.
It was reverted, along with temporary damage-timing instrumentation. The shipped
build uses the resolved upstream dependency without checkout patches.
