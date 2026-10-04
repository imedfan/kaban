#!/usr/bin/env python3
"""Bounded synthetic-only Seatbelt probe. No Cursor, network, auth or system logs.
All fixtures, synthetic HOME, profiles and reports stay in a fresh /private/tmp dir.
A failed launch or non-permission error never counts as a successful denial.
"""
import argparse
import errno
import hashlib
import json
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

PROTECTED = ('.git/config', '.git/hooks/marker', '.git/info/marker', '.kaban/pipeline.yaml')


def child(operation, target, replacement):
    target, replacement = Path(target), Path(replacement)
    try:
        if operation == 'write': target.write_text('changed')
        elif operation == 'unlink': target.unlink()
        elif operation == 'rename': target.rename(replacement)
        elif operation == 'replace': replacement.replace(target)
        elif operation == 'read': target.read_bytes()
        elif operation == 'symlink': target.symlink_to(replacement, target_is_directory=True)
        else: raise ValueError(operation)
    except OSError as error:
        print(json.dumps({'errno': error.errno}))
        return 13 if error.errno in (errno.EACCES, errno.EPERM) else 14
    print(json.dumps({'errno': 0}))
    return 0


def fingerprint(clone):
    return {p: hashlib.sha256((clone / p).read_bytes()).hexdigest() for p in PROTECTED}


def run_probe(template, report_path):
    root = Path(tempfile.mkdtemp(prefix='kaban-protected-probe-', dir='/private/tmp'))
    script = Path(__file__).resolve()
    results = []
    cases = [('write-clone', 'write', 'normal', True), ('write-tmp', 'write', '@tmp/normal', True),
             ('git-status', 'git-status', '', True), ('git-add-index', 'git-add', '', True),
             ('outside-write', 'write', '@outside/normal', False),
             ('read-fake-globalStorage', 'read', '@home/Library/Application Support/Cursor/User/globalStorage/state.vscdb', False),
             ('read-globalStorage-symlink', 'read', 'ide-link', False),
             ('write-outside-symlink', 'write', 'outside-link', False)]
    for p in PROTECTED:
        cases.extend([(f'write-{p}', 'write', p, False), (f'unlink-{p}', 'unlink', p, False),
                      (f'rename-{p}', 'rename', p, False), (f'replace-{p}', 'replace', p, False),
                      (f'symlink-write-{p}', 'write', 'protected-link', False)])
    for p in ('.git', '.git/hooks', '.git/info', '.kaban', '@clone', '@root'):
        cases.append((f'rename-ancestor-{p}', 'rename', p, False))
    for p in ('.git', '.git/config', '.git/hooks', '.git/info', '.kaban'):
        cases.append((f'replace-empty-or-symlink-{p}', 'replace-empty', p, False))
    for p in ('.git', '.kaban'):
        cases.append((f'replace-ancestor-symlink-{p}', 'replace-symlink', p, False))
    try:
        for index, (name, operation, relative, allowed) in enumerate(cases):
            outcomes = []
            for sandboxed in (False, True):
                fixture = root / f'{index}-{int(sandboxed)}'
                clone, temp, cache, fake_home = [fixture / p for p in ('clone', 'tmp', 'cache', 'home')]
                outside = fixture / 'outside'
                for p in (clone, temp, cache, fake_home, outside): p.mkdir(parents=True)
                environment = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(fake_home), 'TMPDIR': str(temp),
                               'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_SYSTEM': '/dev/null', 'GIT_CONFIG_NOSYSTEM': '1',
                               'GIT_TERMINAL_PROMPT': '0', 'PYTHONDONTWRITEBYTECODE': '1', 'LC_ALL': 'C'}
                subprocess.run(['/usr/bin/git', 'init', '-q', str(clone)], env=environment, check=True, timeout=8)
                for p in PROTECTED[1:]:
                    path = clone / p; path.parent.mkdir(parents=True, exist_ok=True); path.write_text('marker')
                ide = fake_home / 'Library/Application Support/Cursor/User/globalStorage/state.vscdb'
                ide.parent.mkdir(parents=True); ide.write_text('marker')
                (outside / 'marker').write_text('marker')
                (clone / 'ide-link').symlink_to(ide)
                (clone / 'outside-link').symlink_to(outside / 'marker')
                protected_index = (index - 8) // 5
                protected_target = clone / PROTECTED[max(0, min(protected_index, 3))]
                (clone / 'protected-link').symlink_to(protected_target)
                replacement = clone / 'replacement'
                replacement.write_text('replacement')
                targets = {'@clone': clone, '@root': fixture}
                if relative in targets: target = targets[relative]
                elif relative.startswith('@tmp/'): target = temp / relative[5:]
                elif relative.startswith('@home/'): target = fake_home / relative[6:]
                elif relative.startswith('@outside/'): target = outside / relative[9:]
                else: target = clone / relative
                actual_op = operation
                if operation == 'replace-symlink':
                    shutil.rmtree(target)
                    target.symlink_to(outside, target_is_directory=True)
                    replacement.unlink()
                    replacement.symlink_to(temp, target_is_directory=True)
                    actual_op = 'replace'
                if operation == 'replace-empty':
                    # Empty dirs and existing symlinks ensure POSIX rename would really succeed.
                    if target.is_dir():
                        shutil.rmtree(target); target.mkdir()
                        replacement.unlink(); replacement.mkdir()
                    else:
                        target.unlink(); target.symlink_to(outside / 'marker')
                    actual_op = 'replace'
                if operation == 'rename':
                    replacement.unlink()
                    if relative == '@root': replacement = root / f'{index}-renamed-fixture'
                    elif relative == '@clone': replacement = fixture / 'renamed-clone'
                before = fingerprint(clone) if operation not in ('replace-empty', 'replace-symlink') else None
                target_inode = target.lstat().st_ino if target.exists() or target.is_symlink() else None
                if operation.startswith('git-'):
                    (clone / 'ordinary.txt').write_text('ordinary')
                    command = ['/usr/bin/git', '-c', 'core.hooksPath=/dev/null', '-c', 'core.fsmonitor=false', '-C', str(clone)]
                    command += ['status', '--porcelain'] if operation == 'git-status' else ['add', '--', 'ordinary.txt']
                else:
                    command = [sys.executable, '-B', str(script), '--child', actual_op, str(target), str(replacement)]
                profile = fixture / 'profile.sb'
                values = {'HOME': fake_home, 'CLONE': clone, 'TMPDIR': temp, 'CACHEDIR': cache, 'MCP_PORT': '43191',
                          'EXTRA_WRITE': '', 'EXTRA_DENY_READ': '', 'EXTRA_DENY_WRITE': ''}
                rendered = template.read_text()
                for key, value in values.items(): rendered = rendered.replace('@@' + key + '@@', str(value))
                if re.search(r'@@[A-Z_]+@@', rendered): raise RuntimeError('unresolved template placeholder')
                profile.write_text(rendered)
                if sandboxed: command = ['/usr/bin/sandbox-exec', '-f', str(profile)] + command
                result = subprocess.run(command, env=environment, cwd=clone, capture_output=True, timeout=8)
                permission_denied = result.returncode == 13 and result.stdout.strip().startswith(b'{')
                outcome = {'sandboxed': sandboxed, 'exit': result.returncode, 'permissionDenied': permission_denied}
                if sandboxed and not allowed:
                    # Denial must leave the target and protected content intact; don't print contents.
                    if before is not None:
                        try: outcome['protectedUnchanged'] = fingerprint(clone) == before
                        except OSError: outcome['protectedUnchanged'] = False
                    else:
                        try: outcome['protectedUnchanged'] = target.lstat().st_ino == target_inode and replacement.exists()
                        except OSError: outcome['protectedUnchanged'] = False
                outcomes.append(outcome)
            baseline, confined = outcomes
            passed = baseline['exit'] == 0 and (confined['exit'] == 0 if allowed else
                      confined['permissionDenied'] and confined['protectedUnchanged'])
            results.append({'case': name, 'expected': 'allow' if allowed else 'deny', 'passed': passed, 'runs': outcomes})
            print(('PASS ' if passed else 'FAIL ') + name, flush=True)
        report = {'os': subprocess.check_output(['/usr/bin/sw_vers', '-productVersion'], text=True).strip(),
                  'build': subprocess.check_output(['/usr/bin/sw_vers', '-buildVersion'], text=True).strip(),
                  'profile': template.name, 'results': results, 'passed': all(r['passed'] for r in results),
                  'limits': ['macOS 26 pending', 'Cursor/runtime/build/network not tested', 'hardlinks and inherited descriptors pending',
                             'broad reads except explicit secret paths', 'only synthetic clone metadata protection']}
        if report_path: report_path.write_text(json.dumps(report, indent=2) + '\n')
        return 0 if report['passed'] else 1
    finally:
        shutil.rmtree(root)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--child', nargs=3, metavar=('OP', 'TARGET', 'REPLACEMENT'))
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    if args.child: sys.exit(child(*args.child))
    if sys.platform != 'darwin': parser.error('requires macOS sandbox-exec')
    sys.exit(run_probe(Path(__file__).with_name('kaban-agent.sb').resolve(), args.report))
