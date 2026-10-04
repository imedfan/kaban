# Protected paths: bounded Seatbelt candidate (#13)

`kaban-agent.sb` is an **experimental deny-default candidate**, not a production
Cursor isolation boundary. The dedicated probe never starts Cursor, contacts a
network endpoint, reads actual HOME/authentication data, or queries system logs.
It builds disposable git repositories, synthetic HOME and marker files under
`/private/tmp`, runs each operation once without Seatbelt and once under the
rendered template, and removes its fixtures. Each subprocess has an eight-second
limit. A launch failure or an error other than EACCES/EPERM fails the assertion;
it is never counted as a protected-path denial. Failed negative operations must
also preserve protected content or the original replacement target inode.

Run only the bounded probe:

```sh
python3 -B spikes/backend/probe-protected-paths.py --report /private/tmp/kaban-protected-report.json
```

An already sandboxed parent may need approval to launch `sandbox-exec` outside
that parent. Approval applies to the synthetic probe, not the full spike6 script.
`spike6-seatbelt.sh` remains a broader runtime discovery experiment with real
HOME/model/network interactions and is **not** a substitute for this probe.

The candidate removes broad `/private/tmp` and `/private/var/tmp` grants. The
launcher must provide independent per-run clone/temp/cache directories, never
their shared writable ancestor or real shared system temp/cache. `EXTRA_WRITE`
is a runtime discovery hook, not an entitlement to permit protected ancestors.
Write denies cover `.git/config`, `.git/hooks`, `.git/info` and `.kaban`; clone
and `.git` ancestor unlink/rename receive explicit denies as well. Ordinary
`.git/index` writes remain permitted: the probe includes `git add`, alongside
ordinary clone/temp writes and `git status`.

The negative matrix checks direct protected writes, unlink, rename, sibling-file
replacement, symlink-mediated writes, rename of protected directories, `.git`,
clone and its parent, replacement of empty protected directories, and replacement
of existing `.git`/`.kaban` symlinks. Empty destinations and unsandboxed successful
controls ensure a POSIX non-empty-directory failure is not mistaken for a denial.
Artificial globalStorage reads, including an alias, and writes outside permitted
directories are also checked. The result JSON records version/build and every
control/negative exit status without fixture contents.

The previous research in `research/macos-seatbelt.md` on branch
`team2/research-seatbelt` documents the original broad allow-default failures.
Those historical observations remain valid for the original template.

## Scope and limits

All **41 cases passed**, each with a successful unsandboxed control; 4 allowed
operations and 37 denial assertions passed. The checked-in result is from
**macOS 27.0.1 (26A434)**, not the target macOS 26. Repeat the
whole matrix on macOS 26 before accepting that platform. Cursor/runtime/build
availability, network rules, inherited descriptors, hardlinks and race attacks
are pending. Broad file reads remain permitted except explicit SSH/globalStorage
paths; this is not a confidentiality whitelist. Git refs/HEAD/packed-refs writes
are not constrained to the task branch by this candidate. Production still needs
the GitShim/daemon boundary and validated clone preparation; no successful marker
test proves the complete hard-invariant or token-isolation requirements.

The renderer/template does not enforce safe path relationships. A trusted launcher
must canonicalize and validate them before execution, close inherited descriptors,
and refuse launch when profile application fails. Seatbelt SBPL is an experimental,
unsupported dependency; a working profile on this host does not establish future
OS compatibility. No live Cursor or full spike6 run was performed for this change.
