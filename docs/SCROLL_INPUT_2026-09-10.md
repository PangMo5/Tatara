# Wheel axes and sidebar scroll margins

> Historical investigation. Commands, dependencies and UI descriptions reflect the
> date of this report. See the [README](../README.md) and [architecture](ARCHITECTURE.md)
> for the current supported behavior.


The previous installed Release (`726205ef7d94a988f867ca0e133bf43ee79a0323c1894607e8a91c58a0d56f90`)
reproduced two independent defects in a 176×40 SwiftTerm PTY:

- TermLoom's pinned input parser mapped SGR wheel buttons 66/67 (horizontal)
  to vertical motion. A left-wheel event moved PR selection, file selection,
  or the Diff viewport upward by three rows. Mixed downward/leftward events
  could cancel each other's movement. Modifier-bearing events had the same defect.
- Sidebar offsets were derived from the selected row without retaining the
  previous viewport. Reversing upward moved the viewport on every selection
  change, even while the selection was far from the upper margin.

The parser now preserves four wheel directions. Horizontal events do not enter
Tatara's vertical-wheel action. A checksum-verified source patch is applied after
dependency installation by `Scripts/Tatara.swift generate`; build validation
rejects missing patches, and unknown dependency content fails instead of silently
applying a potentially stale patch. Remove it when upgrading to an upstream fix.
The [xterm mouse protocol](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html)
defines the distinct wheel button codes.

PR and Files now retain independent viewport offsets. Selection changes leave
the viewport stationary inside its two-row margins. Crossing either margin moves
only as far as needed. Resize, filtering and collapsed trees clamp the offset
against the current visible projection. Mouse hit testing and scrollbar movement
use the same viewport contract.

Validation on the patched Release:

- 85 tests passed, with zero failures or skips. New checks cover four wheel
  directions, modifiers, byte-fragmented input, reversal, boundaries and short panes.
- `--wheel` replays spaced (120 ms) and burst input in PR, Files and Diff;
  horizontal input preserves position and mixed input retains vertical movement.
- The same PTY scenario moves down 20 entries in each sidebar, reverses upward
  through the stationary region, crosses the upper margin, then reverses again.
  It fails on the previous installed binary and passes on the patched binary.
- Workspace mouse/scrollbar/search checks, Vim regression checks and 104×32
  dense directional navigation passed. Catalog, notice and REUSE checks passed.
- The local installation matches the tested Release SHA-256
  `5e74024679a2f46d78c9c08023a5450bd340c97fceca7ecb4ece9ec80fb7f815`.
  The installed executable also passed `--wheel`.

These are terminal-protocol and rendered-output checks, not a capture of a
physical trackpad gesture. They prove the two reproduced defects are corrected;
physical-device feel remains a separate validation boundary.
