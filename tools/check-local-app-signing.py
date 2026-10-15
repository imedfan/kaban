#!/usr/bin/env python3
"""Verify the signed local App/helper policy required by SMAppService."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    args = parser.parse_args()
    checked = []
    for path, identifier in (
        (args.app, 'app.kaban.desktop'),
        (args.app / 'Contents/MacOS/KabanDaemon', 'app.kaban.agent'),
    ):
        subprocess.run(['codesign', '--verify', '--strict', str(path)], check=True)
        details = subprocess.run(['codesign', '-d', '--verbose=4', str(path)],
                                 check=True, capture_output=True, text=True).stderr
        if f'Identifier={identifier}\n' not in details:
            parser.exit(1, f'Unexpected signing identifier: {path}\n')
        if not re.search(r'^CodeDirectory .*flags=.*\bruntime\b', details, re.MULTILINE):
            parser.exit(1, f'Hardened Runtime is missing: {path}\n')
        payload = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(path)],
                                 check=True, capture_output=True).stdout
        entitlements = plistlib.loads(payload) if payload else {}
        if 'com.apple.security.app-sandbox' in entitlements:
            parser.exit(1, f'App Sandbox entitlement must be absent: {path}\n')
        checked.append(identifier)
    print(json.dumps({'result': 'passed', 'identifiers': checked,
                      'hardenedRuntime': True, 'appSandboxEntitlement': False}, indent=2))


if __name__ == '__main__':
    main()
