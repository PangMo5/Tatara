# Current PR summary — November 9, 2026

The workspace summary now shows an explicit Draft/Open/Closed/Merged state,
readable review and CI status, branch direction, file/comment totals, local pending
comment count, colored additions/deletions and commit count. The update timestamp
occupies the lower border. Requested reviewers/teams, assignees, labels and
milestone use remaining rows in that priority order.

The summary uses five to ten rows based on terminal height, retaining most of the
workspace for Files. Long head branches are shortened while retaining the base
branch. Narrow stacked workspaces retain their existing equal Files/Content split.
All values come from existing typed forge snapshots; presentation adds no API
requests. Missing data remains unknown, and known first-page totals survive empty
detail placeholders during loading. Names/labels are bounded to two entries per
group plus a remaining count so view evaluation stays bounded.

161 Release Swift Testing tests passed. New coverage checks all four themes,
Draft/review/check status, changes/commits, the branch target, participant/label
rows, update timestamps, retained totals during loading and honest unknown states.
The current review-experience PTY captures the summary before exercising the
existing comment/draft/final-preview flow; it performs no forge writes.

Raw screenshot: `.artifacts/swift-pty/review-experience/summary.png`.


## Release PTY navigation

The run used 320 × 64 cells, 100 fixture PRs, 120 files, an approximately 2.5 MB
overview and eight 21,000-character source lines. Flags were --wide-lines --burst
--dense-navigation --loading-burst --directional-burst --animated. Fixture storage
was fresh, with the probe's normal PR/file warm-ups and preparation/cache reuse
active during navigation. No compiler, sampler or preview recorder ran alongside
timing samples; unrelated host workload was uncontrolled.

For 588 synchronous root-key dispatches, Store.send p95/max was
0.74/3.04 ms. There were 120 completed-frame observations. PR/file in-flight
selection feedback p95 was 2.23/11.52 ms, with maxima of
2.87/12.12 ms. Individual 64-input burst tails were
5.45/3.99 ms. Initial PR/file readiness was
2104/4183 ms including synthetic provider delays.
Selection feedback is separate from preparation readiness. The frame boundary
includes emulator parsing, not isolated terminal-write CPU or compositor paint.
These observations are not a comparative speed or real GitHub latency claim.

Raw evidence: `.artifacts/swift-pty/navigation-summary/`.
Executable SHA-256: `e6574d35e61631eb58761825a0a61523797a3c68d70656977995c471778a0985`.
