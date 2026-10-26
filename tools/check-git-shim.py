#!/usr/bin/env python3
"""Exercise the compiled git shim's wire, exec and fail-closed behavior without Cursor."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--shim', type=Path, required=True)
    args = parser.parse_args()
    shim = args.shim.resolve(strict=True)
    seen = []
    reply = {'status': 200, 'body': b'{"allow":true}'}

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            seen.append((self.path, self.headers.get('Authorization'),
                         json.loads(self.rfile.read(int(self.headers['Content-Length'])))))
            if reply.get('stall'):
                time.sleep(3)
            self.send_response(reply['status'])
            self.send_header('Location', f'http://127.0.0.1:{self.server.server_port}/redirect')
            self.end_headers()
            try:
                self.wfile.write(reply['body'])
            except (BrokenPipeError, ConnectionResetError):
                pass

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    message = 'команда запрещена политикой проекта, запрос отправлен человеку; продолжай без неё или дождись разрешения\n'
    with tempfile.TemporaryDirectory(prefix='kaban-shim-') as directory:
        root = Path(directory)
        marker = root / 'executed'
        real = root / 'real-git'
        real.write_text('#!/bin/sh\nprintf executed >> "$MARKER"\nprintf "git-out\\n"\nprintf "git-err\\n" >&2\ncat\nexit 37\n')
        real.chmod(0o755)
        env = {**os.environ, 'KABAN_RUN_TOKEN': 'test-token', 'KABAN_GIT_BIN': str(real),
               'KABAN_GIT_CHECK_URL': f'http://127.0.0.1:{server.server_port}/git/check',
               'MARKER': str(marker)}
        argv = ['commit', '-m', 'spaces "quotes" \\ and\nUnicode: ё', '--', 'tab\tfile']

        def run(environment=None):
            return subprocess.run([str(shim), *argv], cwd=root, env=environment or env,
                                  input='stdin\n', text=True, capture_output=True, timeout=5)

        result = run()
        assert (result.returncode, result.stdout, result.stderr) == (37, 'git-out\nstdin\n', 'git-err\n'), result
        assert marker.read_text() == 'executed'
        assert seen == [('/git/check', 'Bearer test-token', {'argv': argv, 'cwd': str(root.resolve())})], seen
        # Every subsequent refusal must leave the real executable's bytes untouched.
        for status, body in [(200, b'{"allow":false}'), (401, b'{"allow":true}'),
                             (500, b'{"allow":true}'), (200, b'bad json'), (200, b'{}'),
                             (200, b'{"allow":1}'), (200, b'{"allow":"true"}'), (302, b'{"allow":true}')]:
            reply.update(status=status, body=body)
            count = len(seen)
            result = run()
            assert (result.returncode, result.stderr, result.stdout) == (1, message, ''), (status, body, result)
            assert len(seen) == count + 1  # In particular, never follow a redirect.
            assert marker.read_text() == 'executed'
        reply.update(status=200, body=b'{"allow":true}', stall=True)
        started = time.monotonic()
        result = run()
        assert result.returncode == 1 and result.stderr == message
        assert time.monotonic() - started < 4
        reply.pop('stall')
        for key in ['KABAN_RUN_TOKEN', 'KABAN_GIT_BIN', 'KABAN_GIT_CHECK_URL']:
            broken = env.copy()
            broken.pop(key)
            result = run(broken)
            assert result.returncode == 1 and result.stderr == message
        for url in ['https://127.0.0.1:80/git/check', 'http://example.invalid/git/check',
                    'http://127.0.0.1:80/other']:
            result = run({**env, 'KABAN_GIT_CHECK_URL': url})
            assert result.returncode == 1 and result.stderr == message
        result = run({**env, 'KABAN_GIT_BIN': str(shim)})
        assert result.returncode == 1 and result.stderr == message
        server.shutdown()
        server.server_close()
        result = run()
        assert result.returncode == 1 and result.stderr == message
        assert marker.read_text() == 'executed'
    print(json.dumps({'result': 'passed', 'shim': str(shim), 'execExit': 37,
                      'argvAndCwd': True, 'stdinAndStreams': True, 'failClosed': True,
                      'redirectsRejected': True, 'timeout': True}))


if __name__ == '__main__':
    main()
