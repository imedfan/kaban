# FE-22 acceptance evidence

Baseline `593e755`; initial QA source `440f766`, final QA source `8a041a2`.
App source changes are inside `KABAN_QA`. Production Release has no fixture/QA symbols.
The report and UC-01–25 matrix are in
[frontend-fe-22-2026-10-30.md](../../docs/development/frontend-fe-22-2026-10-30.md).

- `automated-initial.json`: complete first run, 44/46 automated steps passed;
  strict UI focus failed in both themes. Initial failure logs are retained.
- `automated-final.json` / `.log`: final source, **46/46 automated steps passed**;
  result `automated_passed_live_unverified`. Signing and Mach-O check logs are
  retained alongside it. Nested-script evidence remains at paths in the logs.
- `ui-launchservices-repeat.json`: separate strict UI repeat via LaunchServices,
  before the explicit QA foreground activation fix. Not a replacement for the
  original failures.
- `swift-tests.txt`: five test-executable totals, 777 tests, full local log hash.
- `free-cursor.json`: current CLI version, auth boolean and approved model
  presence only; no account fields, credentials or paid prompts.
- `load-sample-excerpt.txt`: one-second main-thread profile excerpt and hash
  of the full local sample during the initial 10×500 light workload.
- Actual final WindowGroup PNGs are in
  [screenshots/fe-22](../../docs/development/screenshots/fe-22).

The manifests contain observed checkout HEAD/dirty state, executable hashes,
commands, timings, scope, reports and absolute local evidence paths. Prebuilt
product source provenance is recorded in the report; the observed checkout HEAD
alone does not establish it. Nested private-daemon scripts print their own fresh
evidence directories into step logs. All paid Cursor starts: **0**.

Automated workload completion does not establish responsiveness: initial
10×500 runs have main-actor gaps of 9.7–11.2 seconds. Installed XPC, notifications,
bundle update, reboot, accessibility and the four-run live acceptance are open.
