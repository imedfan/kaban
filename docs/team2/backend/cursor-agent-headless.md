# B5 — Cursor Agent headless handoff

B5 and T1 are one research task. The canonical memo is
[research/cursor-agent-cli.md](../../../research/cursor-agent-cli.md)
(checked 2026-10-04, architecture v0.11.22 / spec v0.8.24).

It contains installed-build help observations (`2026.09.23-86fc751`), dated
primary sources, argv, init/result schema, outcome classification, isolated
mbp commands and fixture destinations. Observed/documented/unknown are
separate; no paid or authenticated run and no real quota fixtures are claimed.

Backend priorities: treat missing result separately from process timeout;
require the stage's MCP completion contract; compare init display name with
catalog before tools; preserve unknown fields and missing metrics. Absence of
`--force` alone does not establish a tested read-only boundary.

Next fixtures (owner-authorized mbp runs): success/resume, invalid model,
no-force/deny, timeout/signal, empty-HOME auth, and naturally encountered
monthly-limit/resource-exhausted/silent-exit cases. Public samples belong in
`docs/team2/backend/samples/<case>/` after manual sanitization. No samples are
included yet. LaunchAgent and credential storage remain unverified.
