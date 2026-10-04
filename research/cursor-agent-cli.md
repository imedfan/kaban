# Cursor Agent CLI: T1 / B5, spike 1

Checked 2026-10-04. Baseline: `origin/main` at `1d647ea`.
Product authority: Drive architecture v0.11.22 §§6, 7, 13, 14;
spec v0.8.24 §6; decisions-log. Repository copies are older.
This is a research handoff, not a tested driver contract.

Evidence labels: **Observed** = bounded local non-model probe;
**Documented** = official documentation; **Unknown** = needs mbp fixture;
**Kaban rule** = product decision, not a Cursor guarantee.
No authenticated/model run, credential/IDE-data read, installation,
login/logout, global configuration change or launchd registration was performed.

## Sources

All web sources accessed 2026-10-04; the pages expose no publication date.
Recheck against mbp's installed version before running a spike.

| ID | Primary source | Use |
|---|---|---|
| P | [Parameters](https://cursor.com/docs/cli/reference/parameters) | argv and commands |
| O | [Output format](https://cursor.com/docs/cli/reference/output-format) | stream and failure contract |
| A | [Authentication](https://cursor.com/docs/cli/reference/authentication) | status, browser/API-key auth |
| H | [Headless CLI](https://cursor.com/docs/cli/headless) | file changes in print mode |
| C | [Configuration](https://cursor.com/docs/cli/reference/configuration) | config paths and override |
| R | [Permissions](https://cursor.com/docs/cli/reference/permissions) | explicit deny rules |

Local sources read without modification:
[spike 1](../spikes/backend/spike1-cursor-agent.sh),
[capture wrapper](../spikes/backend/capture-run.sh),
[process/parser helper](../spikes/backend/lib/kspike.py),
[spike guide](../spikes/backend/README.md).

## Observed installed CLI

Binary `/Users/artem/.local/bin/cursor-agent`; version `2026.09.23-86fc751`.
`--version`, `--help`, `mcp --help`, `status --help` each completed within
30 seconds, exit 0, empty stderr. Help calls establish syntax, not behavior.
Current docs use executable name `agent`; Kaban can retain the discovered
absolute `cursor-agent` path. Never assume the launchd PATH finds either.

| Option / command | Observed help meaning | Kaban consequence |
|---|---|---|
| `-p`, `--print` | Non-interactive; all tools including write/shell | Always pass explicitly |
| `--output-format stream-json` | Only with print; text/json also available | Capture stdout as NDJSON |
| `--model <model>` | Explicit model; parameter overrides supported | Required stage id; forbid Auto |
| `--list-models`, `models` | List models and exit | Catalog shape unknown until capture |
| `-f`, `--force`, `--yolo` | Allow commands unless explicitly denied | Preserve invariant deny rules |
| `--approve-mcps` | Approve every MCP server | First verify same-environment allowlist |
| `--resume [chatId]` | Select session to resume | Pass concrete captured session id |
| `--continue` | Continue previous session | Avoid ambiguous latest-session selection |
| `--stream-partial-output` | Incremental text deltas | Optional; duplicates need handling |
| `--mode plan`, `--mode ask` | Read-only modes in help | Not a replacement for Seatbelt policy |
| `--sandbox enabled\|disabled` | Override sandbox mode | Separate from external Seatbelt |
| `--trust` | Trust workspace without prompting | Measure need in a fresh synthetic repo |
| `--workspace <path-or-name>` | Defaults to cwd | Use one task clone, not saved workspace |
| `--api-key`, `CURSOR_API_KEY` | API-key authentication | Use environment; no key in argv/log |
| `mcp list` | Servers and their status | Human-readable shape not yet observed |
| `status --format json` | JSON status output | Non-model auth check; fields unobserved |

Help also exposes `--add-dir`, `--plugin-dir`, Cursor-managed `--worktree`,
`--auto-review`, `--endpoint`, `--header`. Kaban must not inherit extra roots,
plugins, endpoint overrides or automatic permission changes accidentally.
No root `--mcp-config`, `--config`, `--debug`, `--verbose` or log-file flag
was advertised by this build. Absence in help is not proof none exists.

**Documented tension:** H says print without force proposes changes;
P and installed help say print has write/shell access. R specifies permission
allow/deny, with deny taking precedence. Therefore **Unknown**: whether all
write paths are blocked without force in this build. Do not equate missing
`--force` with an OS read-only boundary. This preserves architecture §8.2.

MCP discovery, project/global precedence and fail-closed probes are owned by
[T2 isolation research](mcp-config-isolation.md); that separate PR supplies
this link. The same binary, cwd, HOME, config and environment must be used
for the list preflight and actual run (Kaban rule).

## Stream, actual model, resume

**Documented, O:** NDJSON uses `system/init`, `user`, `assistant`,
`tool_call` started/completed, and a terminal `result` on success.
`init` includes `session_id`, display-name `model`, `cwd`, `apiKeySource`,
`permissionMode`. Success result includes `subtype=success`, `is_error=false`,
`duration_ms`, `duration_api_ms`, text `result`, `session_id`, optional
`request_id`. Failure may end without result and has nonzero exit/stderr.
Unknown added fields should be preserved/ignored rather than rejected.
Partial-output assistant events can repeat text; consuming final result
avoids double counting. These are documentation examples, not live fixtures.

**Unknown:** actual `usage`, tokens, currency/cost, `fallbackModel`,
mid-session substitution, init after resume, and model names vs catalog ids.
The published success schema does not promise usage/cost. Missing metrics
mean unavailable, never zero. No billing decision can use a synthetic sample.

**Kaban rule:** compare init's display name with requested catalog name.
Known mismatch → kill before first tool, `model_substituted`, no attempt debit.
Missing/ambiguous name → `model_unconfirmed`, continue per current decision.
The stream documents no reliable model identity after init. Buffer tool events
until identity decision; a late init cannot justify accepting earlier tools.
Resume must still pass explicit `--model`; equal session id does not prove
that model selection survived resume.

## Outcomes for a fake driver

| Observation | Evidence / interpretation | Capture needed |
|---|---|---|
| Normal success | O documents result; observed help exits 0 only | Real result plus process exit |
| Failure | O says nonzero + stderr, possibly no result | Exact exit mapping not documented |
| Exit 0, no result | Unknown real behavior; incomplete run | Keep stdout, stderr, final board call |
| CLI success, no `complete_stage` MCP call | Agent did not satisfy Kaban stage contract | Do not mark stage complete |
| Wrapper timeout | Helper records `timed_out=true`, exit 124 | Wrapper value, not Cursor exit guarantee |
| SIGTERM / SIGKILL | Python negative signal return vs shell 128+signal | Keep raw wait status and killer reason |
| Crash / spawn error | Separate from model/API refusal | stderr, launch error, no inference of quota |
| Monthly limit | Kaban: `usage limit` / `spendLimitHit` → `usage_exhausted` | Real fixture; optional billing reset field |
| Model exhausted | Kaban: `resource_exhausted` / slow-pool text → model unavailable | Real fixture; model id/name/fallback |
| Other throttling | Kaban: rate-limited with cooldown | Real retry/reset data; no invented duration |
| Logged out / expired key | A documents status, not numeric failure codes | Empty-HOME status + actual error capture |
| Invalid model | Unknown numeric code or fallback behavior | Invalid-id fixture; not a quota fixture |

Do not retry to exhaust paid quotas. Capture monthly/resource/peak cases only
when encountered in ordinary owner-authorized work. A regex match is a
classifier hint, not evidence that every matching error means the same thing.
Silent exit and timeout remain different: an exited process cannot time out.
Kaban's attempt accounting and priority come from §6.4, not exit code alone.

## Safe mbp capture checklist

These are future owner-run commands. The paid lines below were not run.
All generated data stays in a temporary directory. Substitute the binary
path on mbp; do not install or alter shell/global configuration.

```bash
CA=/Users/artem/.local/bin/cursor-agent
KS="$PWD/spikes/backend/lib/kspike.py"  # run from repository root
TD=$(mktemp -d /private/tmp/kaban-team2-cli.XXXXXX)
mkdir -p "$TD/repo" "$TD/out" "$TD/home" "$TD/config"
GIT_CONFIG_GLOBAL=/dev/null git -C "$TD/repo" init -q
probe() {
  name=$1; shift
  python3 "$KS" run --timeout 30 --out "$TD/out/$name" -- "$CA" "$@"
}
probe version --version
probe help --help
probe mcp-help mcp --help
probe status-help status --help
# No model generation; status may include personal account data: keep private.
probe status status --format json
probe catalog --list-models
python3 "$KS" models "$TD/out/catalog.stdout" --save "$TD/out/catalog.json"
```

Expected: capture version, available flags, catalog `id/name` shape, private
status and exits. A status failure is not necessarily logged-out (network,
endpoint and sandbox errors are alternatives). `status` need not validate
future network/API access or remaining quota. No `logout` is needed.

```bash
# Empty HOME test: process-scoped only; no login or credentials copied.
python3 "$KS" run --timeout 30 --cwd "$TD/repo" \
  --out "$TD/out/empty-home-status" -- /usr/bin/env -i \
  HOME="$TD/home" PATH=/usr/bin:/bin "$CA" status --format json
# Config override test, retain existing HOME but no API-key injection.
python3 "$KS" run --timeout 30 --cwd "$TD/repo" \
  --out "$TD/out/config-dir-status" -- /usr/bin/env -i \
  HOME="$HOME" PATH=/usr/bin:/bin CURSOR_CONFIG_DIR="$TD/config" \
  "$CA" status --format json
# Sparse launchd-like environment, not a launchd registration.
python3 "$KS" run --timeout 30 --cwd "$TD/repo" \
  --out "$TD/out/sparse-status" -- /usr/bin/env -i \
  HOME="$HOME" PATH=/usr/bin:/bin "$CA" status --format json
```

**Documented, C:** global config is `~/.cursor/cli-config.json`; project
`.cursor/cli.json` supports permissions; `CURSOR_CONFIG_DIR` overrides config.
**Unknown:** whether this also relocates credentials, chats, logs and MCP.
**Documented, A:** browser credentials are stored locally; their exact path,
Keychain service and refresh policy are unspecified. Status is the supported
non-model check. API key in env is the documented automation alternative.
Do not copy credentials into an isolated HOME to make a failed probe pass.
Do not read `state.vscdb`, CLI auth files or personal global configuration.
The SDK's separate auth path is not evidence about this CLI's storage.
Actual LaunchAgent access to Keychain/network is **Unknown**; sparse-env
success is only a prerequisite. Under the no-system-change scope, no
`launchctl bootstrap`, login or Keychain modification is prescribed here.
Architecture §7's unofficial quota endpoint, `billingCycleStart`, and IDE
read access remain owner-controlled spike questions, not validated APIs.

### Minimal paid probes (owner selects explicit cheap model)

Use only after T2 verifies the actual MCP server set, and the owner authorizes
model cost. Even a no-tools prompt is not a security boundary. Keep cwd
synthetic; wrap in the tested external sandbox for the full isolation check.

```bash
MODEL='REPLACE_WITH_EXPLICIT_CATALOG_ID'  # never auto
run_case() {
  name=$1; shift
  python3 "$KS" run --timeout 90 --line-times --cwd "$TD/repo" \
    --out "$TD/out/$name" -- "$CA" -p --output-format stream-json \
    --model "$MODEL" "$@"
}
run_case success 'Reply with the single word OK. Do not use tools.'
python3 "$KS" sj "$TD/out/success.stdout" --save "$TD/out/success.summary.json"
SID=$(python3 "$KS" sj "$TD/out/success.stdout" --get init.session_id)
[ -n "$SID" ] || SID=$(python3 "$KS" sj "$TD/out/success.stdout" --get result.session_id)
# Proceed only when SID is non-empty; inspect init/model and fresh result.
[ -n "$SID" ] && run_case resume --resume "$SID" 'Reply OK. Do not use tools.'
rm -f "$TD/repo/probe.txt"
run_case no-force 'Create probe.txt containing OK. Do not run shell commands.'
# Record no-force file existence first; reset the synthetic file before comparison.
[ -e "$TD/repo/probe.txt" ] && echo no-force-created-file
rm -f "$TD/repo/probe.txt"
run_case force --force 'Create probe.txt containing OK. Do not run shell commands.'
# Invalid id may unexpectedly fall back: capture, never accept its result.
python3 "$KS" run --timeout 90 --line-times --cwd "$TD/repo" \
  --out "$TD/out/bad-model" -- "$CA" -p --output-format stream-json \
  --model kaban-no-such-model-0000 'Reply OK. Do not use tools.'
```

Record file existence/diff after each write probe, tools attempted/denied,
init before first tool, result fields, exit, stderr and timing. For force/deny
precedence, put synthetic `.cursor/cli.json` with
`{"permissions":{"deny":["Write(denied.txt)","Shell(touch)"]}}`
in `$TD/repo` only, repeat `--force` with a request to write `denied.txt`;
expected denial needs a real fixture. No global permission edits.
For fallback: compare catalog, init and any error `fallbackModel` fields;
if no natural fallback occurs, leave unknown. For monthly/resource/peak
errors use the same `run_case` wrapper at the natural incident; do not loop.

### Cancellation, logs and fixture layout

`kspike.py run` owns a process group, bounded timeout and line timestamps.
For a timeout fixture use `--timeout 1` on an authorized paid run; retain
`timed_out`, raw/translated exit and group-survivor metadata. This tests the
wrapper's cancellation, not Cursor's quota behavior. Explicit signal behavior is still unknown. A separate owner-authorized
synthetic SIGTERM probe (same MCP/sandbox prerequisites as paid probes):

```bash
python3 "$KS" killtest --timeout 40 --delay 1 --grace 2 --wait-after 3 \
  --cwd "$TD/repo" --out "$TD/out/sigterm" \
  --sentinel "$TD/repo/late.txt" -- "$CA" -p --output-format stream-json \
  --model "$MODEL" --force \
  'Run sleep 20; then create late.txt containing LATE. Do nothing else.'
```

Expected: terminate the owned group after first tool-start, capture tree and
survivors, no late sentinel. If no tool starts, this does not test SIGTERM.
Forced SIGKILL only happens if the group survives grace; mark unexercised
otherwise. Do not run the whole spike 1 script under this task's scope.

Existing default capture destination is
`spikes/backend/out/fixtures/<case>/`; spike 1 writes under
`spikes/backend/out/spike1-cursor-agent-<timestamp>/fixtures/`.
`capture-run.sh` stores `stream.jsonl`, `stderr.txt`, `exit_code`, `meta.json`,
`times.jsonl`, `summary.json`, `context.txt`, catalogs and limit hits.
It also reads status and enumerates personal log paths; its wider collection
is not required for the safe minimal probes above. Wrapper script exit 0 is
not agent success: read the captured exit and metadata.

For each `$TD/out/<case>.*`, preserve stdout as `stream.jsonl`, stderr,
exit/meta/times and summary under a private `<version>/<case>/` folder.
Record date/timezone, binary version, requested model id/name, expected vs
actual init name, environment variable *names*, synthetic repo description,
termination reason and sandbox status. Never save an environment dump.
Public sanitized real fixtures go in `docs/team2/backend/samples/<case>/`
(new files, separate small PR). No real samples exist in this handoff.
Run `python3 "$KS" scrub "$TD/out"`, then manually inspect for prompts,
paths, account identifiers, tool output and secrets before sharing. Regex
scrubbing is not proof of anonymity. Keep exact error labels/field structure.
CLI log location is **Unknown** and no debug flag was advertised; do not
invent a path or ingest personal logs. Captured stdout/stderr is sufficient.

## Remaining owner / backend decisions

- Confirm catalog machine format and stable id→display-name mapping per build.
- Obtain real monthly-limit, resource-exhausted and silent-exit fixtures;
  exact exit/error mappings, resets and attempt-debit rules cannot be inferred.
- Confirm force/no-force, trust/approval, resume/model and signal behavior.
- Choose auth transport for isolated HOME; then test actual LaunchAgent under
  explicit owner-controlled scope. Credential location remains unresolved.
- Decide whether mid-run model identity absence is an accepted limitation.

Validation here: official pages reviewed; four local help/version probes;
Markdown links/command syntax checked. No production code changed. Confidence:
high for observed syntax, medium for documented stream schema, low for the
unobserved account-specific, fallback, quota and launchd behavior.
