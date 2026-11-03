# Compact frame storage — September 9–10, 2026

> Historical investigation. Commands, dependencies and UI descriptions reflect the
> date of this report. See the [README](../README.md) and [architecture](ARCHITECTURE.md)
> for the current supported behavior.


The final SwiftTUI candidate passed all 73 framework gate steps and actual
Tatara PTY checks. Work in this phase is local; no pull request or remote
publication was made.

## Representation

ResolvedNode, MeasuredNode, and PlacedNode keep their child arrays inline and
store other metadata in a private single-element ContiguousArray. Copies share
metadata until standard-library copy-on-write isolates a writer. Borrowing
accessors avoid copying a payload merely to inspect it. Each node value occupies
16 bytes on this arm64 build. This is the value size, not total heap size or a
claim about reduced application memory use.

Boxed now uses standard-library COW instead of a custom mutable storage class,
mutex, and read/write snapshots. No unchecked Sendable or unsafe memory access
was introduced. Equality, cache reuse rules, and derived-field updates remain
intact, including subtree counts, damage bounds, preferences, runtime stamps,
and reuse certification.

The first prototype also nested child arrays inside metadata. Full-suite
testing exposed a real regression: an additional recursive ARC layer exhausted
the worker stack while naturally releasing 1,024-level trees. Keeping child
edges inline removes that layer. A process-isolated regression test covers
natural release on a worker-sized stack for all three node types. The existing
iterative drain still handles trees beyond the natural bound.

## Actual Tatara navigation

The baseline is the previously installed input-dispatch improvement. Both
binaries use the same Tatara application implementation. Three runs per variant
and size alternated execution order, each with independent fixture storage and
configuration. Each replays 8, 32, and 64 consecutive j inputs at 25 ms spacing
in both PR and file panes, followed by diff paging. All 12 runs completed
without missing motions or failed selection assertions.

Latency ends at the first completed synchronized terminal frame whose
selection includes the input; coalesced motions can share a frame. Each
pane/size/variant has 312 input observations; paging has 48 observations.
No build, test, diagnostic capture, CPU sample, or preview recording ran
alongside these timing replays. Other desktop apps remained active. Figma and
Codex renderer processes were using CPU at launch; their contribution to any
individual outlier was not established.

| Terminal | Action | Baseline p95 | Final p95 | Change |
| --- | --- | ---: | ---: | ---: |
| 104 × 56 | PR selection | 80.80 ms | 74.06 ms | 8.3% lower |
| 104 × 56 | File selection | 151.51 ms | 136.53 ms | 9.9% lower |
| 104 × 56 | Diff page | 49.92 ms | 50.52 ms | 1.2% higher |
| 320 × 64 | PR selection | 172.46 ms | 84.66 ms | 50.9% lower |
| 320 × 64 | File selection | 188.61 ms | 148.27 ms | 21.4% lower |
| 320 × 64 | Diff page | 87.77 ms | 76.10 ms | 13.3% lower |

These are pooled p95 values. The 320-column baseline PR p95 varied from
106.72 to 203.16 ms. Comparing the median of the three per-run p95 values gives
112.10 → 84.98 ms (24.2%), a more conservative view than the pooled 50.9%.
File p95 improved in five of six paired runs. The third 104-column pair
regressed from 159.29 to 186.10 ms, and the candidate's pooled maximum increased
from 225.34 to 271.12 ms. Small-screen paging p95 did not improve meaningfully.

Final evidence: .artifacts/compact-frame-storage/final-navigation-summary.json
and final-per-run-summary.json. Earlier navigation-summary.json and stage
binaries describe the first prototype and are not final evidence.

## Controlled framework comparison

Three alternating pairs of native Release runs each create a fresh renderer
and graph for 30 cold iterations per workload. Each median excludes the first
three iterations; process-global type caches can remain warm. The table gives
the median of three run medians. Every deterministic counter matched across
baseline and candidate, and all benchmark ratchets passed.

| Native workload | Baseline | Final | Reduction |
| --- | ---: | ---: | ---: |
| Deep grid | 78.40 ms | 47.06 ms | 40.0% |
| Dynamic properties | 7.56 ms | 6.03 ms | 20.2% |
| Memo boundary | 35.78 ms | 24.84 ms | 30.6% |

These results establish lower representation overhead for these workloads;
they do not replace actual Tatara input measurements. Raw reports and the
counter comparison are listed in final-cold-summary.json.

## Validation

- bun run test: all 73 gate steps passed, including policy, Core/Graph,
  runtime shards (180, 837, and 2,638 tests), CLI/platform, and 140 tool tests.
- Focused Core/Graph: 1,360 tests passed. Deep teardown: 8 tests passed,
  including the new natural-release regression.
- Clean native Release and fresh-DerivedData Tatara Release builds passed.
  Code-signature verification passed.
- Actual Tatara PTY checks passed: tree/list configuration, pane borders,
  Shift-V on both source sides, review preview, presets, search, popup, mouse
  wheel, scrollbar, paging, resizing, Escape, cross-process cache reuse, and
  focus changes during large PR/diff preparation. Resized source ranges and
  continuous source text were independently checked. No forge writes occurred.

## Source identity and remaining limits

Evidence lives under .artifacts/compact-frame-storage/. The final-framework.patch
and final-source-identity.json record the exact patch, changed source digests,
composition, and executable hashes. Build sources match the final implementation.

| Artifact | Identity |
| --- | --- |
| Framework base | 0cb77fae6e74742a2b0d6d6ca08640501c3970f9 |
| Tatara composition base | 8885d3be06f0a8e269c82198956da720a4e8e65a |
| Baseline executable SHA-256 | 43fa9caafe1a057825ab7d11b09df49fe786adaf59b94b2c431412d0f07c7e3f |
| Final executable SHA-256 | 0bb94ef8153c16b22efb3a14c3ae1d022e1499c4f2d1a5584fd2677acbd23f4f |
| Framework patch SHA-256 | 2b8c4e829f583d1588c2b608e19cb7f09f385460256f6d9f3114a72c40cf178a |

Host: Apple M4 Max, macOS 27.0, Xcode 26.6, Apple Swift 6.3.3. The manifest still
pins 1c359c27f6bc983a436df80db9f6df3bbc7c3df0. The experimental build temporarily
used the local composition checkout. The original dependency link and Debug
build defaults were restored; a normal manifest build does not automatically
include this local patch.

This reduces value-copy and reference-management overhead. It does not make
all rendering proportional to changed content or establish a theoretical
minimum latency. Visible tails remain; the complete SwiftTUI app has not
reached the earlier reduced-feature renderer prototype's latency.
