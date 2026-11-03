# Security

Report a security issue privately through
[GitHub vulnerability reporting](https://github.com/PangMo5/Tatara/security/advisories/new).
Private vulnerability reporting is enabled. Do not publish tokens, private source,
terminal recordings containing secrets or active exploit details in a public issue.

Tatara delegates authentication to `gh` and does not copy tokens into its config.
Remote code is compared as bytes, not executed. Temporary snapshots are scoped
to a private directory and removed after diff rendering. Remote content is not
checked out over a user's worktree. Terminal control sequences are not executed.

Before retrying a write after a timeout, inspect the original review on GitHub:
a failed response does not prove the server rejected the write.
