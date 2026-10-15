#!/usr/bin/env python3
"""Check BE-23 through real daemon pipes and SQLite, using a non-model CLI fixture."""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import select
import sqlite3
import subprocess
import tempfile
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", type=Path, required=True)
    args = parser.parse_args()
    daemon = (args.bin_dir / "KabanDaemon").resolve()
    if not daemon.is_file():
        parser.error("Build KabanDaemon first")
    root = Path(tempfile.mkdtemp(prefix="kaban-be23-", dir="/tmp"))
    database = root / "store.sqlite"
    runner = root / "cursor agent"
    mode = root / "mode"
    mode.write_text("ready")
    runner.write_text("""#!/bin/sh
dir=$(/usr/bin/dirname "$0")
printf '%s\\n' "$1" >> "$dir/calls"
case "$1" in
  --version) printf 'fixture-be23-1.0\\n' ;;
  status)
    if [ "$(/bin/cat "$dir/mode")" = ready ]; then printf 'ready\\n'; else printf 'not logged in\\n'; exit 1; fi ;;
  --list-models) printf 'fixture-model\\tFixture Model\\n' ;;
  *) exit 99 ;;
esac
""")
    runner.chmod(0o755)

    @contextmanager
    def host(name, extra=()):
        with (root / (name + ".log")).open("w") as log:
            process = subprocess.Popen([str(daemon), "--stdio", "--initialize", "--database", str(database), *extra],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)

            def request(operation):
                process.stdin.write(json.dumps({"protocolVersion": 1, "operation": operation}).encode() + b"\n")
                process.stdin.flush()
                data = bytearray()
                deadline = time.monotonic() + 10
                while b"\n" not in data:
                    remaining = deadline - time.monotonic()
                    assert remaining > 0 and select.select([process.stdout], [], [], remaining)[0], "Daemon reply timed out"
                    chunk = os.read(process.stdout.fileno(), 65_536)
                    assert chunk, "Daemon closed the reply pipe"
                    data.extend(chunk)
                    assert len(data) <= 8 * 1024 * 1024, "Oversized reply"
                return json.loads(data)["result"]

            def send(kind, payload=None, command_id=None):
                envelope = {"protocolVersion": 1, "commandId": command_id or str(uuid.uuid4()).upper(),
                            "command": {kind: payload or {}}}
                return request({"command": {"_0": envelope}})["command"]["_0"]

            try:
                yield request, send
            finally:
                process.stdin.close()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
                    raise
                process.stdout.close()
                assert process.returncode == 0, (name, process.returncode)

    missing = root / "not-installed"
    with host("missing", ["--cursor-agent", str(missing)]) as (request, send):
        snapshot = request({"snapshot": {}})["snapshot"]["_0"]
        assert {"level": "mac", "flag": "runner_unavailable", "reason": "agent_missing"} in snapshot["schedulerFlags"], snapshot
        capabilities = request({"capabilities": {}})["capabilities"]["_0"]
        commands = {row["name"]: row["support"] for row in capabilities["commands"]}
        assert all(commands[name] == "supported" for name in ["configureCursor", "getCursorEnvironment", "checkEnvironment"])
        command_id = str(uuid.uuid4()).upper()
        configured = send("configureCursor", {"environment": {"executablePath": str(runner)}}, command_id)
        assert configured["result"] == {"ok": {}}, configured
        calls = (root / "calls").read_text()
        assert send("configureCursor", {"environment": {"executablePath": str(runner)}}, command_id) == configured
        assert (root / "calls").read_text() == calls, "Replay launched another probe"
        report = send("checkEnvironment")["result"]["environment"]["_0"]
        assert report["cursorAgentPath"] == str(runner) and report["version"] == "fixture-be23-1.0" and report["authOK"]
        models = send("listModels")["result"]["models"]["_0"]
        assert [row["id"] for row in models] == ["fixture-model"], models
        page = request({"subscribe": {"fromSeq": 0, "limit": 256}})["events"]["_0"]
        assert any(event.get("commandId") == command_id and event["event"]["type"] == "cursorEnvironmentChanged" for event in page["events"]), page
        assert send("configureCursor", {"environment": {"executablePath": "relative"}})["result"]["error"]["_0"]["code"] == "cursor_environment_invalid"

    with host("restart") as (request, send):
        environment = send("getCursorEnvironment")["result"]["cursorEnvironment"]["_0"]
        assert environment == {"executablePath": str(runner)}, environment
        mode.write_text("logged-out")
        assert send("recheck", {"scope": {"runner": {}}})["result"] == {"ok": {}}
        flags = request({"snapshot": {}})["snapshot"]["_0"]["schedulerFlags"]
        assert {"level": "mac", "flag": "runner_unavailable", "reason": "agent_not_logged_in"} in flags, flags
        runner.chmod(0o644)
        send("recheck", {"scope": {"runner": {}}})
        flags = request({"snapshot": {}})["snapshot"]["_0"]["schedulerFlags"]
        assert {"level": "mac", "flag": "runner_unavailable", "reason": "agent_not_runnable"} in flags, flags

    with sqlite3.connect(database) as connection:
        saved = json.loads(connection.execute("SELECT payload FROM cursor_environment WHERE id = 1").fetchone()[0])
    assert saved["configuration"]["executablePath"] == str(runner)
    assert set((root / "calls").read_text().splitlines()) <= {"--version", "status", "--list-models"}
    result = {"result": "passed", "source": "real daemon/private stdio; synthetic CLI; no launchd or model starts",
              "checks": ["startup missing flag", "capabilities", "configure event", "replay without another probe",
                         "environment report", "immediate catalog", "restart persistence", "logged-out and non-executable flags"],
              "evidence": str(root)}
    (root / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
