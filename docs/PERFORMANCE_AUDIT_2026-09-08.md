# Responsiveness audit — September 8, 2026

The measurements below use SwiftTUI 0.10.1 and precede the subsequent dependency
update to SwiftTUI 0.11.3 and difftastic 0.70.0. The recorded executable hashes
identify those measured builds; these timings do not describe later builds.

## Scope

Reviewed all authored runtime sources in TataraCore, TataraKit, TataraSystem,
TataraGitHub, TataraPersistence, and TataraTUI, plus tests, build settings, and the
SwiftTerm PTY harness. Tatami's input/worker/ownership principles were adapted to
terminal selection, source anchors, and synchronized output in `AGENTS.md`.
Guidance stays durable; this dated report owns implementation details and evidence.

The baseline is commit `38628681c919a6928965c71953eb4d6246d4d481`, rebuilt locally
in Release from the unchanged baseline sources and kept separately from the
refactored executable. The dependency graph and dependency sources were unchanged
during this audit.

## Findings and changes

| Area | Finding | Result |
| --- | --- | --- |
| Bootstrap | Configuration file reads and TOML decoding ran in the UI task. | Explicit concurrent loading; cancellation cannot publish bootstrap state or errors. |
| Workspace reads | Detail, diff misses, and search imposed 120/80/60 ms delays. | Reads start immediately, previous generations are cancelled, and stale responses are rejected. |
| Sidebar | Filtering and tree visibility were recomputed during navigation and view evaluation. | Derived rows and item/file position indices update with their actual inputs and are reused by views and input handlers. |
| Search | Building the full match-membership set happened when applying the response on the main actor. | The worker returns ordered matches and membership together. Enter commits the query without repeating the search; pending results are labelled as pending. |
| Diff cursor | Movement allocated remaining-row arrays; nearest-side lookup scanned the document. | Immutable per-side indices support logarithmic lookup without row-sized allocations. |
| Review anchors | Opening or adding a comment reparsed the entire patch on the main actor. | Changed-file snapshots precompute hunk indices; single-hunk source validation remains required. |
| Preview ownership | Failed replacement removed the loading flag and could expose old content as current. | Presentation generations keep stale previews labelled and block their review/search actions, including after error dismissal. |
| Theme | Changing palette unnecessarily restarted diff preparation and reset visual selection. | Semantic colors repaint the prepared document while preserving scroll and selection. |
| Diff service | Parsing, serialization, and file preparation occupied the cache actor; duplicate reads could overlap. | Heavy work runs concurrently outside that actor. Active reads share a producer with per-consumer cancellation and flight identity. |
| Memory caches | Detail/snapshot overflow flushed whole caches; snapshot byte accounting could retain an oversized value. | Incremental LRU eviction, count/estimated-byte limits, and oversized-entry rejection preserve useful entries. Binary diff results are cached too. |
| Forge | Some boundaries relied on implicit nonisolated async execution and cancellation after returning to TCA. | Worker isolation is explicit; cancellation is checked before decoding/caching and before launching a command. |
| Presets | An old initial load could clear a newer save's busy state. | Read cancellation plus response generations preserve the active operation. |
| Persistence | Database reads/writes already use worker isolation and transactions. | Account/host/repository scoping, atomic writes, expiry, and bounded pruning are retained. |
| Presentation | Source projections and viewports were already bounded; wrapping avoids document-sized glyph-cache locks. | Those contracts remain. Full source and search text are preserved independently of clipped output. |
| Writes | Reviews require a preview and fresh remote revision validation; writes are not retried. | Those contracts remain; tests and PTY runs publish no forge writes. |

## Validation and measurements

- XcodeBuildMCP: 62 tests passed, 0 failed, 0 skipped; Debug and Release builds succeeded.
- Formatting, 108 catalog strings in five locales, notices for 25 resolved packages,
  Catppuccin notices, and REUSE checks passed.
- PTY: demo with real difftastic, four themes, five languages, tree/list, review
  preview and ranges, persistent presets, search, help, mouse wheel, scrollbar,
  resize, warm process restart, and in-flight stress checks passed. No forge writes.
- Unit coverage includes stale responses, failed-preview ownership, cached revisits,
  LRU eviction, source-hunk decoding, concurrent diff sharing, and producer cancellation.

Controlled runs used an Apple M4 Max with 48 GB RAM, macOS 27.0 (26A5425a),
320 × 64 terminal cells, and isolated fixture caches. Own builds and CPU samplers
were idle during measurements. Each workload was run once per executable; the
small sample counts do not support a broad statistical claim.

The wide workload has eight roughly 21,000-character source rows; the large
workload has 25,000 changed source rows. Both include a roughly 2.5 MB PR paragraph,
a 2-second fixture detail read, and a 4-second fixture diff process. Those external
delays remain in the cold-read measurements. Navigation phases warm both selected
PRs and files before the settled/in-flight/burst comparisons.

Times below are milliseconds, measured to completed synchronized PTY output.
For burst rows, the sample is the final help key after sixteen alternating j/k
keys at the stated intervals, not every individual key's latency.

| Workload | Interaction | Samples per build | Median before → after | p95 before → after | Maximum before → after |
| --- | --- | ---: | ---: | ---: | ---: |
| Wide | Warm PR selection | 8 | 41.3 → 40.2 | 41.8 → 41.5 | 41.8 → 41.5 |
| Wide | Warm file selection | 16 | 43.2 → 38.9 | 53.7 → 40.4 | 53.7 → 40.4 |
| Wide | PR selection during replacement | 24 | 42.7 → 41.5 | 44.9 → 43.9 | 45.8 → 44.2 |
| Wide | File selection during replacement | 24 | 45.2 → 41.9 | 48.8 → 43.9 | 49.2 → 125.9 |
| Wide | Diff cursor | 16 | 42.2 → 42.0 | 43.2 → 43.6 | 43.2 → 43.6 |
| Wide | Type and commit content search | 6 | 163.9 → 145.6 | 166.5 → 149.4 | 166.5 → 149.4 |
| Wide | PR burst, 25 ms cadence | 3 | 147.0 → 130.7 | 152.1 → 139.2 | 152.1 → 139.2 |
| Wide | File burst, 25 ms cadence | 3 | 141.0 → 110.6 | 151.7 → 120.3 | 151.7 → 120.3 |
| Wide | PR burst, 120 ms cadence | 3 | 72.2 → 69.3 | 81.0 → 70.9 | 81.0 → 70.9 |
| Wide | File burst, 120 ms cadence | 3 | 66.5 → 65.4 | 66.6 → 66.8 | 66.6 → 66.8 |
| 25,000 rows | Warm PR selection | 8 | 39.7 → 39.2 | 40.9 → 40.4 | 40.9 → 40.4 |
| 25,000 rows | Warm file selection | 16 | 48.6 → 45.3 | 50.1 → 49.9 | 50.1 → 49.9 |
| 25,000 rows | PR selection during replacement | 24 | 41.0 → 41.5 | 43.3 → 44.2 | 43.5 → 45.0 |
| 25,000 rows | File selection during replacement | 24 | 49.0 → 46.1 | 50.3 → 49.7 | 150.5 → 144.9 |
| 25,000 rows | Diff cursor | 16 | 49.4 → 49.2 | 52.2 → 51.0 | 52.2 → 51.0 |
| 25,000 rows | Type and commit content search | 6 | 223.8 → 205.9 | 228.2 → 208.6 | 228.2 → 208.6 |
| 25,000 rows | PR burst, 25 ms cadence | 3 | 137.8 → 124.0 | 143.2 → 136.3 | 143.2 → 136.3 |
| 25,000 rows | File burst, 25 ms cadence | 3 | 151.6 → 139.8 | 151.9 → 154.2 | 151.9 → 154.2 |
| 25,000 rows | PR burst, 120 ms cadence | 3 | 70.5 → 69.9 | 70.5 → 70.9 | 70.5 → 70.9 |
| 25,000 rows | File burst, 120 ms cadence | 3 | 125.5 → 75.1 | 133.8 → 75.6 | 133.8 → 75.6 |

The wide cold PR selection reached readiness in 2316.8 → 2127.9 ms; its cold
file reached readiness in 4259.2 → 4112.7 ms. The large workload recorded
2246.9 → 2196.9 ms and 4824.8 → 4780.7 ms respectively. Each is one cold sample;
these are not pure preparation timings.

Both before/after request dictionaries were identical in each workload: 22 `gh`
processes, two diff renders, and one diff-version query. This verifies reuse for
these warmed sequences, not an API-rate claim about uncached navigation on GitHub.

Synchronous `Store.send` remained around 0.21–0.23 ms median, with all recorded
maxima below 1.5 ms. Large-workload frame diagnostics changed from 142.65 →
139.88 ms p95 and 181.51 → 176.56 ms maximum for `input_to_commit_first_ms`.
These framework-stage metrics are separate from the final help-key and search
measurements in the table.

File selection and search showed modest improvements. Cursor presentation was
essentially unchanged despite removing its linear input work. The large file
burst maximum did **not** improve (151.9 → 154.2 ms); this audit does not establish
that rapid-navigation pauses are fully resolved. Wide in-flight file selection
also had a higher maximum in the paired run (49.2 → 125.9 ms). A separate baseline
run on the same executable reached 135.1 ms in that phase
(`navigation-audit-baseline`); maxima vary between runs.

### Reproducible evidence

- Baseline executable SHA-256:
  `50a1be3ebada9b6e9d64ac8cff9d2e2e1c2b692a79fba56a585599d95fe7fc11`.
- Final executable SHA-256:
  `5da8226e935bd44019ab4488b65f958ba02ee4b11f74268cfca0922ea64713cc`.
- Raw samples, request logs, input traces, and frame summaries:
  `.artifacts/swift-pty/navigation-audit-{baseline-v2,final-wide,baseline-large,final-large}/`.
- Build/test/check logs and preserved executables:
  `.artifacts/performance-audit/`.

```sh
swift Scripts/Tatara.swift smoke PATH_TO_BINARY --navigation LABEL --wide-lines --burst
swift Scripts/Tatara.swift smoke PATH_TO_BINARY --navigation LABEL --burst
```


## Evidence boundaries

Synthetic `gh` and `difft` fixtures isolate workload and cache state. Their delays
represent external work, not real GitHub latency. PTY measurements include output
transport and SwiftTerm parsing, but not a terminal application's compositor or
physical display. Live GitHub API latency and very large review-draft editing were
not benchmarked here. A successful unit test or a faster cursor lookup does not prove
that every end-to-end navigation pause has disappeared.

The framework's frame pipeline can still delay input presentation while a frame
is being acquired. No renderer dependency was patched or replaced during this
audit. Remaining tail latency must be reported from the measured workload rather
than hidden by new debounce/settling timers.
