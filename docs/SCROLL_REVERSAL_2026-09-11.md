<!-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors -->

> Historical investigation. Commands, dependencies and UI descriptions reflect the
> date of this report. See the [README](../README.md) and [architecture](ARCHITECTURE.md)
> for the current supported behavior.

<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Wheel direction reversal investigation

The previous installed Release reproduced delayed direction reversal under high-frequency wheel input. Tatara's wheel reducer changes only a bounded viewport offset and returns no asynchronous effect. Every mouse event requests a redraw. TermLoom's application loop reads one event, applies the update, then completes a presentation/frame before reading the next event. `TerminalInput` retains parsed events in FIFO order. Consequently, old wheel inputs each cause a frame before the reverse-direction event is reached.

Sources: the pinned [TermLoom application loop](https://raw.githubusercontent.com/Frank-III/termloom/b746967794ad2753c39f695f5923c5cdf2f6425a/Sources/TermLoom/Application.swift), `TerminalInput` in `TerminalSession.swift`, Tatara's `TerminalWorkspace.update`, `WorkspaceInput.handleMouse`, and the `wheelScrolled` reducer.

## Reproduction

`Scripts/Smoke/.build/release/tatara-smoke $HOME/.local/share/tatara/local/bin/tatara --wheel-reversal installed-320 --columns 320 --rows 64`

The helper prepares a 25,000-line synthetic Diff before measuring. An independent input writer sends 60 downward then 60 upward SGR wheel events, with no application-provided inertia. SwiftTerm records only completed synchronized frames. Each scenario starts and ends at viewport offset 1, reaches offset 181, and emits all 120 scrolling frames. The selected pane remains unchanged. The same installed binary is used throughout: SHA-256 `2b7b9a03a7161a99b2b99a8708105a7b062cf85fa8bd61d7befb7bb540579204`.

| Terminal | Requested input interval | Old-direction frames after reversal input | First reversed frame | Tail after last input |
| --- | ---: | ---: | ---: | ---: |
| 320 x 64 | 1 ms | 28 | 64.92 ms | 128.18 ms |
| 320 x 64 | 4 ms | 0 | 2.62 ms | 3.07 ms |
| 320 x 64 | 12 ms | 0 | 3.11 ms | 4.69 ms |
| 176 x 48 | 1 ms | 4 | 5.58 ms | 7.57 ms |
| 176 x 48 | 4 ms | 0 | 1.62 ms | 1.84 ms |
| 176 x 48 | 12 ms | 0 | 1.88 ms | 1.59 ms |

These are individual controlled replay scenarios, not a distribution of physical gestures. Actual send timestamps are retained because scheduler timing differs from the requested interval. At high frequency, opposite-direction input is already written into the PTY while the application continues emitting old-direction frames. At slower rates, the queue stays caught up. Render cost and incoming wheel-event density both affect the delay; this is not evidence that every terminal/trackpad gesture has the same latency.

The earlier wheel suite verified axes, final positions, focus and cursor preservation, with read windows between motions. It did not verify direction reversal while input was arriving faster than frame production. The new `--wheel-reversal` probe records this previously missing condition.

## Implemented correction

Tatara now opts into `coalescesScrollPresentation` in the TermLoom runtime. Nonblocking lookahead consumes consecutive wheel events at the same pointer position and with the same modifiers, applying each state transition in order. The runtime presents after at most 64 wheel events, when no complete event is immediately available, or before a different input. Key, click, resize, pointer-position and modifier boundaries retain ordered handling; application suspension/history-reset operations also end batching. A single retained boundary event preserves the original FIFO order. Other applications keep per-event rendering by default.

Lookahead never flushes a partial Escape sequence merely because a zero-time poll has no input. The normal input path retains its existing standalone-Escape behavior. No input is dropped, no wheel delta is replaced by a net sum, and no timer, animation or debounce was added. Batching reduces intermediate frames while preserving viewport boundary clamping, source cursor, selection and focus semantics.

`Scripts/Patches/termloom-scroll-presentation.patch` carries the upstream MIT attribution. Generation applies it with original/patched SHA-256 guards; a mismatched upstream file fails visibly. The patch was also applied to pristine saved source copies and verified byte-for-byte against the built sources.

Initial investigation logs remain in `.artifacts/reversal-installed-{320,176}.log`, with frame traces in `.artifacts/swift-pty/wheel-reversal-installed-{320,176}/reversal.json`.

## Validation after the correction

The `Tatara` Debug scheme executed 103 tests with zero failures or skips. New runtime PTY tests cover bounded wheel batches, per-event clamping through reversal, keyboard/click/pointer boundaries, default opt-out behavior, fragmented Escape sequences and cancellation. Release built successfully without reported compiler warnings/errors. The Release wheel suite (rich density), workspace/cache/resize suite, presentation suite and Unicode editor suite passed. Format, catalog, notices, REUSE and whitespace checks passed.

The unchanged old executable and the new Release were measured sequentially with the same 320 x 64 prepared Diff and input writer. Each interval was repeated three times. Values below are ranges across those repetitions, not population percentiles.

| Build | Input interval | Old-direction frames after reversal | First reversed frame | Tail after last input |
| --- | ---: | ---: | ---: | ---: |

| Previous | 1 ms | 30–35 | 75.71–84.81 ms | 148.90–159.21 ms |
| Previous | 4 ms | 0–0 | 2.59–3.28 ms | 2.66–3.00 ms |
| Previous | 12 ms | 0–0 | 3.15–4.50 ms | 3.09–4.30 ms |
| Corrected | 1 ms | 1–1 | 3.67–5.39 ms | 2.68–3.68 ms |
| Corrected | 4 ms | 0–0 | 2.35–3.06 ms | 2.43–3.25 ms |
| Corrected | 12 ms | 0–0 | 3.14–4.37 ms | 3.35–4.33 ms |

The corrected 176 x 48 run also repeated each cadence three times. At the 1 ms requested interval, reversed-frame latency was 1.27–1.46 ms, with one old-direction frame and a 1.19–1.68 ms tail. One frame may already be rendering when the opposing input is written; the growing replay of old-direction frames was removed in these workloads. The actual first 60 inputs took about 75 ms in the fastest scenario, rather than exactly 60 ms, due to host scheduling. These measurements do not prove physical display or trackpad latency.

The replay also sent downward wheel input, Tab, then upward wheel input as one continuous sequence. Final viewport position and expected keyboard pane were preserved. Full traces and binary identities are under `.artifacts/swift-pty/wheel-reversal-{baseline-320,candidate-320,candidate-176}/reversal.json`; the successful test result is `.artifacts/reversal-tests-success.json`.

The corrected Release SHA-256 is `e762ec9be84f0211aacaace76650655a82e60e44102fc1de8a04d63f180ec693`.


Installation completed at `$HOME/.local/share/tatara/local/bin/tatara`; its SHA-256 matches the corrected Release above. A final replay launched from that installed path passed all three cadences and the mixed wheel/Tab sequence. At the 1 ms requested interval, reversal took 4.26 ms, with one old-direction frame and a 3.67 ms tail. The final trace is `.artifacts/swift-pty/wheel-reversal-installed-final/reversal.json`. Restart any previously running Tatara process to load the replacement executable.


## Follow-up: document boundaries and the running executable

A reported recurrence was traced to a process that still held the pre-install executable inode. After relaunch, the running process inode matched the installed file, and the user confirmed the symptom was resolved. No additional runtime change was necessary.

The added `--wheel-boundary LABEL` replay prepares an 80-line source, reaches the bottom or top, continues sending the same direction for a total of 240 wheel events, then reverses six events. In the installed 320 x 64 run, the boundary was reached about 288–294 ms before reversal; reversed output arrived in 4.93 ms at the bottom and 3.44 ms at the top. Final offsets, keyboard focus and the source cursor were preserved. The cursor assertion reads its footer status, since the on-screen cursor marker legitimately leaves the viewport during independent scrolling. Trace: `.artifacts/swift-pty/wheel-boundary-installed/boundary.json`.
