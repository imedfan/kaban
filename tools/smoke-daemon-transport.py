#!/usr/bin/env python3
"""Exercise real daemon/CLI processes with temporary storage, without launchd or Cursor."""
import argparse
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
    ctl = (args.bin_dir / "kabanctl").resolve()
    with tempfile.TemporaryDirectory(prefix="kaban-transport-") as temporary:
        root = Path(temporary)
        database = root / "store.sqlite"
        base = [str(ctl), "--stdio-daemon", str(daemon), "--database", str(database)]

        def run(*command, success=True):
            result = subprocess.run(base + list(command), text=True, capture_output=True, timeout=15)
            assert (result.returncode == 0) == success, (command, result.returncode, result.stderr)
            return json.loads(result.stdout)

        def envelope(kind, command_id=None):
            return {"protocolVersion": 1, "commandId": command_id or str(uuid.uuid4()), "command": {kind: {}}}

        def send(value, success=True):
            path = root / "request.json"
            path.write_text(json.dumps(value), encoding="utf-8")
            return run("send", str(path), success=success)

        assert run("snapshot")["seq"] == 0
        capabilities = run("capabilities")
        commands = {entry["name"]: entry["support"] for entry in capabilities["commands"]}
        assert commands["restoreWIP"] == "unsupported" and commands["createTask"] == "managedFakeOnly"
        replacement = run("synchronize")
        assert replacement["snapshot"]["seq"] == 0 and replacement["cursor"]["offset"] == 0
        assert replacement["current"] == []
        pause = envelope("pauseAll")
        receipt = send(pause)
        assert receipt["seq"] == 1 and "ok" in receipt["result"], receipt
        # Every CLI invocation opens a new child daemon and reopens SQLite.
        assert send(pause) == receipt
        paused = run("snapshot")
        assert paused["seq"] == 1 and paused["schedulerFlags"], paused
        conflict = send(envelope("resumeAll", pause["commandId"]), success=False)
        assert conflict["result"]["error"]["_0"]["code"] == "command_id_conflict", conflict
        refusal = envelope("createTask")
        refusal["command"]["createTask"] = {"projectId": "missing", "title": "Task", "body": "Body"}
        first_refusal = send(refusal, success=False)
        assert send(refusal, success=False) == first_refusal
        resumed = send(envelope("resumeAll"))
        assert resumed["seq"] == 2
        page = run("subscribe", "0")
        assert [event["seq"] for event in page["events"]] == [1, 2] and not page["resyncRequired"], page

        with sqlite3.connect(database) as connection:
            connection.execute("DELETE FROM event")
        assert run("snapshot")["seq"] == 2
        assert run("subscribe", "0")["resyncRequired"]
        assert send(envelope("pauseAll"))["seq"] == 3

        # A second runtime must refuse the same database before recovery or a command.
        owner = subprocess.Popen([str(daemon), "--stdio", "--database", str(database)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        def read_reply():
            data = bytearray()
            deadline = time.monotonic() + 5
            while b"\n" not in data:
                remaining = deadline - time.monotonic()
                assert remaining > 0 and select.select([owner.stdout], [], [], remaining)[0], "Daemon reply timed out"
                chunk = os.read(owner.stdout.fileno(), 65_536)
                assert chunk, "Daemon closed its reply pipe"
                data.extend(chunk)
                assert len(data) <= 8 * 1024 * 1024, "Oversized daemon reply"
            return json.loads(data)

        try:
            owner.stdin.write(json.dumps({"protocolVersion": 1, "operation": {"snapshot": {}}}) + "\n")
            owner.stdin.flush()
            assert read_reply()["result"]["snapshot"]["_0"]["seq"] == 3
            owner.stdin.write(json.dumps({"protocolVersion": 1, "operation": {"synchronize": {}}}) + "\n")
            owner.stdin.flush()
            synced = read_reply()["result"]["replacement"]["_0"]
            assert synced["snapshot"]["seq"] == 3
            owner.stdin.write(json.dumps({"protocolVersion": 1, "operation": {"ephemeral": {"after": synced["cursor"], "limit": 1}}}) + "\n")
            owner.stdin.flush()
            live = read_reply()["result"]["ephemeral"]["_0"]
            assert live["events"] == [] and live["nextCursor"] == synced["cursor"] and not live["resetRequired"]
            owner.stdin.write(json.dumps({"protocolVersion": 1, "operation": {"readLog": {"runId": "missing", "fromOffset": 0, "limit": 1}}}) + "\n")
            owner.stdin.flush()
            assert read_reply()["result"]["error"]["_0"]["code"] == "unsupported_operation"
            duplicate = subprocess.run([str(daemon), "--stdio", "--database", str(database)], input="", text=True, capture_output=True, timeout=5)
            assert duplicate.returncode != 0 and "writerAlreadyRunning" in duplicate.stderr, duplicate.stderr
            owner.stdin.write("malformed\n")
            owner.stdin.flush()
            assert read_reply()["result"]["error"]["_0"]["code"] == "invalid_request"
        finally:
            owner.stdin.close()
            owner.wait(timeout=5)
        assert run("snapshot")["seq"] == 3
    print("Daemon/CLI smoke passed: capabilities, replacement/live cursors, unavailable logs, reopen/replay, refusal, conflict, catch-up, retention, single writer and malformed input.")


if __name__ == "__main__":
    main()
