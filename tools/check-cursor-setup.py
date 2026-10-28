#!/usr/bin/env python3
"""FE-23 actual WindowGroup/private daemon acceptance; synthetic CLI, no model calls."""
import argparse
import fcntl
import importlib.util
import json
import sqlite3
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    args = parser.parse_args()
    executable = args.app.resolve() / 'Contents/MacOS/Kaban'
    if not executable.is_file():
        parser.error('Build the Debug App first')
    root = Path(tempfile.mkdtemp(prefix='kaban-fe23-', dir='/tmp'))
    runner = root / 'Очень длинный каталог Cursor CLI с пробелами/bin/cursor-agent'
    runner.parent.mkdir(parents=True)
    runner.write_text('''#!/bin/sh
dir=$(/usr/bin/dirname "$0")
root=$(/usr/bin/dirname "$(/usr/bin/dirname "$dir")")
printf '%s\\n' "$1" >> "$root/calls"
case "$1" in
 --version) printf 'fixture-fe23-1.0\\n' ;;
 status) if [ "$(/bin/cat "$root/mode")" = ready ]; then printf 'ready\\n'; else printf 'not logged in\\n'; exit 1; fi ;;
 --list-models) [ "$(/bin/cat "$root/mode")" = ready ] || exit 1; printf 'fixture-model\\tFixture Model\\n' ;;
 *) exit 99 ;;
esac
''')
    runner.chmod(0o755)
    (root / 'mode').write_text('ready')
    repo = root / 'repo'
    (repo / '.kaban/skills').mkdir(parents=True)
    spec = importlib.util.spec_from_file_location('pipeline_qa', Path(__file__).with_name('check-pipeline-editor.py'))
    pipeline = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pipeline)
    (repo / '.kaban/pipeline.yaml').write_text(pipeline.YAML.replace('model: explicit', 'model: fixture-model'))
    (repo / '.kaban/skills/dev.md').write_text('Cursor settings acceptance fixture.\n')
    for git_args in [['init', '-b', 'main'], ['config', 'user.name', 'Cursor QA'],
                     ['config', 'user.email', 'cursor@example.test'], ['add', '.'], ['commit', '-m', 'QA source']]:
        subprocess.run(['git', '-C', str(repo), *git_args], check=True, capture_output=True)
    print(root, flush=True)

    def run(name, mode, theme='light', minimum=False, onboarding=False, bottom=False):
        report = root / (name + '.json')
        command = [str(executable), '-ApplePersistenceIgnoreState', 'YES', '--developer',
                   '--developer-database', str(root / 'store.sqlite'), '--qa-task-suite', 'kaban.qa.fe23.' + root.name,
                   '--cursor-live-smoke', str(report),
                   '--qa-cursor-mode', mode, '--qa-theme', theme, '--export-live-window', str(root / (name + '.png'))]
        if not (root / 'store.sqlite').exists():
            command += ['--qa-cursor-agent', str(root / 'not-installed')]
        if minimum:
            command += ['--qa-size', 'minimum']
        if onboarding:
            command += ['--qa-onboarding', 'real']
        if bottom:
            command += ['--qa-onboarding-scroll', 'bottom']
        if mode == 'picker':
            command += ['--qa-model-picker', 'yes', '--qa-pipeline-stage', 'dev', '--qa-pipeline-section', 'Исполнитель']
        with (root / (name + '.log')).open('w') as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=90)
        if not report.is_file() or result.returncode or json.loads(report.read_text()).get('result') != 'passed':
            raise RuntimeError(f'{name}: inspect {root / (name + ".log")} and {report}')
        with (root / 'store.sqlite.daemon.lock').open('rb') as lease:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(lease, fcntl.LOCK_UN)
        # Reconciliation may cover the receipt with a snapshot before live
        # journal delivery. Independently verify the exact persisted event.
        data = json.loads(report.read_text())
        command_id = data['checks']['configurationCommandID']
        if command_id and mode != 'invalid':
            with sqlite3.connect(root / 'store.sqlite') as connection:
                events = [json.loads(row[0]) for row in connection.execute('SELECT payload FROM event')]
            matching = [event for event in events if event.get('commandId') == command_id
                        and event['event']['type'] == 'cursorEnvironmentChanged']
            assert len(matching) == 1, matching
            assert Path(matching[0]['event']['data']['executablePath']).samefile(runner)
            data['checks']['exactDurableEventVerified'] = True
            report.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
        print(name + ': passed', flush=True)

    run('missing-onboarding-light', 'missing', onboarding=True)
    run('missing-settings-dark-minimum', 'missing', 'dark', True)
    run('invalid-settings-light', 'invalid')
    runner.chmod(0o644)
    run('not-runnable-settings-dark-minimum', 'not-runnable', 'dark', True)
    runner.chmod(0o755)
    (root / 'mode').write_text('logged-out')
    run('logged-out-onboarding-light-bottom', 'logged-out', onboarding=True, bottom=True)
    run('logged-out-settings-dark-minimum', 'logged-out', 'dark', True)
    run('recheck-settings-light', 'recheck')
    run('configure-onboarding-dark-minimum', 'configure', 'dark', True, True, True)
    run('restart-settings-dark-minimum', 'restart', 'dark', True)
    run('catalog-picker-light', 'picker')
    run('offline-settings-light', 'offline')
    calls = set((root / 'calls').read_text().splitlines())
    assert calls <= {'--version', 'status', '--list-models'}, calls
    print('Evidence: ' + str(root), flush=True)


if __name__ == '__main__':
    main()
