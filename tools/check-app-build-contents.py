#!/usr/bin/env python3
"""Check actual Kaban Mach-O types for production/QA build separation."""
import argparse
import json
from pathlib import Path
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--qa', action='store_true', help='Expect an explicitly enabled QA build')
    args = parser.parse_args()
    executable = args.app / 'Contents/MacOS/Kaban'
    binaries = [executable]
    debug_library = executable.with_name('Kaban.debug.dylib')
    if debug_library.is_file():
        binaries.append(debug_library)
    raw = b'\n'.join(subprocess.check_output(['nm', '-a', str(binary)], stderr=subprocess.DEVNULL)
                     for binary in binaries)
    symbols = subprocess.check_output(['xcrun', 'swift-demangle', '--compact'], input=raw).decode()
    types = set(re.findall(r'\bKaban\.([A-Za-z][A-Za-z0-9_]*)', symbols))
    demo = sorted(name for name in types if name.startswith('Reference') or name in {
        'NativeShell', 'NativeSettingsView', 'NativeAddProjectForm', 'NativeReturnForm'})
    qa = sorted(name for name in types if name.startswith('QA') or name in {
        'AppFixture', 'BoardQA', 'NativeWindowCapture'})
    if demo:
        parser.exit(1, 'Demo types found in application: ' + ', '.join(demo) + '\n')
    if not args.qa and qa:
        parser.exit(1, 'QA types found in production application: ' + ', '.join(qa) + '\n')
    required = {'KabanTheme', 'KabanChip', 'KabanMascot', 'KabanBackdrop', 'KabanWordmark'}
    if args.qa:
        required |= {'AppFixture', 'BoardQA', 'NativeWindowCapture'}
    missing = sorted(required - types)
    if missing:
        parser.exit(1, 'Required application types missing: ' + ', '.join(missing) + '\n')
    print(json.dumps({'result': 'passed', 'qaEnabled': args.qa,
                      'demoTypes': demo, 'qaTypes': qa,
                      'requiredTypes': sorted(required)}, indent=2))


if __name__ == '__main__':
    main()
