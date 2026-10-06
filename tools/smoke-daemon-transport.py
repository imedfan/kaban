#!/usr/bin/env python3
"""Exercise real daemon/CLI processes with temporary storage, without launchd or Cursor."""
import argparse
import hashlib
import json
import os
import re
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
        assert commands["restoreWIP"] == "unsupported" and commands["createTask"] == "supported" and commands["addProject"] == "supported"
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

        # Real local project lifecycle, including host startup reconciliation on every CLI call.
        repo = root / "project"
        repo.mkdir()
        def git(*arguments):
            result = subprocess.run(["/usr/bin/git", "-C", str(repo), *arguments], text=True, capture_output=True, timeout=15)
            assert result.returncode == 0, result.stderr
            return result.stdout
        git("init", "-b", "main")
        git("config", "user.name", "Smoke Author")
        git("config", "user.email", "smoke@example.test")
        (repo / "Package.swift").write_text("// swift-tools-version: 6.1\n")
        (repo / "tracked.txt").write_text("initial\n")
        git("add", "Package.swift", "tracked.txt")
        git("commit", "-m", "Initial")
        (repo / "tracked.txt").write_text("staged\n")
        git("add", "tracked.txt")
        (repo / "tracked.txt").write_text("unstaged\n")
        staged = git("diff", "--cached", "--binary", "--", "tracked.txt")
        unstaged = git("diff", "--binary", "--", "tracked.txt")
        addition = envelope("addProject")
        addition["command"]["addProject"] = {"path": str(repo), "createTemplate": True}
        added = send(addition)
        assert "ok" in added["result"] and send(addition) == added
        assert git("diff", "--cached", "--binary", "--", "tracked.txt") == staged
        assert git("diff", "--binary", "--", "tracked.txt") == unstaged
        assert all(path.startswith(".kaban/") for path in git("diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD").splitlines())
        snapshot = run("snapshot")
        assert len(snapshot["projects"]) == 1
        project_id = snapshot["projects"][0]["id"]
        assert snapshot["projects"][0]["identity"]["name"] == "Smoke Author"
        task = envelope("createTask")
        task["command"]["createTask"] = {"projectId": project_id, "title": "Production Backlog", "body": "Description\n\n## Критерии приёмки\n- [ ] Works"}
        created = send(task)
        task_id = created["result"]["taskCreated"]["_0"]
        assert run("snapshot")["tasks"][0]["stageId"] == "backlog"
        gate_query = envelope("detectGates")
        gate_query["command"]["detectGates"] = {"projectId": project_id}
        assert send(gate_query)["result"]["gates"]["_0"] == ["swift build", "swift test"]
        # Exact transported YAML fixes the committed invalid template. The source identity also
        # binds nil-version drafts, and every response is reopened in a new daemon process.
        pipeline = snapshot["pipelines"][0]
        pipeline_file = repo / ".kaban/pipeline.yaml"
        valid_yaml = re.sub(r"^(\s+model:).*", r"\1 smoke-model", pipeline_file.read_text(), flags=re.MULTILINE)
        content_hash = "sha256:" + hashlib.sha256(valid_yaml.encode()).hexdigest()
        draft = {"projectId": project_id, "baseVersionHash": None, "baseSourceHash": pipeline["sourceHash"], "contentHash": content_hash, "content": valid_yaml}
        validation = envelope("validatePipelineDraft")
        validation["command"]["validatePipelineDraft"] = {"draft": draft}
        resolved = send(validation)["result"]["pipelineDraft"]["_0"]
        assert not any(issue["severity"] == "error" for issue in resolved["issues"]), resolved
        update = envelope("updatePipeline")
        update["command"]["updatePipeline"] = {"projectId": project_id, "contentHash": content_hash, "draft": draft}
        pipeline_file.write_text(valid_yaml)
        applied = send(update)
        assert "pipelineVersion" in applied["result"] and send(update) == applied
        assert pipeline_file.read_text() == valid_yaml
        assert git("diff", "--cached", "--binary", "--", "tracked.txt") == staged
        assert git("diff", "--binary", "--", "tracked.txt") == unstaged
        assert run("snapshot")["pipelines"][0]["versionHash"] == applied["result"]["pipelineVersion"]["hash"]
        # Explicit persisted test settings; the daemon never guesses missing global settings.
        with sqlite3.connect(database) as connection:
            settings = {"maxConcurrentRuns": 3, "quotaOptions": {"enabled": False, "consent": False, "pollInterval": 300, "thresholdCm": 10, "thresholdOm": 10}}
            connection.execute("INSERT INTO global_settings(id, payload) VALUES (1, ?)", (json.dumps(settings).encode(),))
        moved = root / "moved-project"
        owner = subprocess.Popen([str(daemon), "--stdio", "--database", str(database)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            def owner_snapshot():
                owner.stdin.write(json.dumps({"protocolVersion": 1, "operation": {"snapshot": {}}}) + "\n")
                owner.stdin.flush()
                return read_reply()["result"]["snapshot"]["_0"]
            def owner_command(value):
                owner.stdin.write(json.dumps({"protocolVersion": 1, "operation": {"command": {"_0": value}}}) + "\n")
                owner.stdin.flush()
                result = read_reply()["result"]["command"]["_0"]
                assert "error" not in result["result"], result
                return result
            assert owner_snapshot()["projects"][0]["availability"] == "available"
            # Live committed reload must run on the background observer without restarting.
            pipeline_file.write_text(valid_yaml.replace("model: smoke-model", "model: auto"))
            git("add", ".kaban")
            git("commit", "-m", "Manual invalid pipeline")
            deadline = time.monotonic() + 8
            while not any(issue["code"] == "model_auto_forbidden" for issue in owner_snapshot()["pipelines"][0]["issues"]):
                assert time.monotonic() < deadline, "Live pipeline observer did not reload main"
                time.sleep(0.2)
            pipeline_file.write_text(valid_yaml)
            git("add", ".kaban")
            git("commit", "-m", "Fix manual pipeline")
            deadline = time.monotonic() + 8
            while owner_snapshot()["pipelines"][0].get("versionHash") is None:
                assert time.monotonic() < deadline, "Live pipeline observer did not clear invalid main"
                time.sleep(0.2)
            # Live host scheduling, with no explicit tick and no fake/Cursor worker.
            for n in range(3):
                queued = envelope("createTask")
                queued["command"]["createTask"] = {"projectId": project_id, "title": f"Queued {n}", "body": "Task\n\n## Критерии приёмки\n- [ ] Ready"}
                owner_command(queued)
            head_before_start = git("rev-parse", "HEAD")
            checkout_before_start = git("status", "--porcelain")
            owner_command(envelope("resumeAll"))
            deadline = time.monotonic() + 8
            while True:
                scheduled = owner_snapshot()
                running = [task for task in scheduled["tasks"] if task["state"]["status"] == "running"]
                if len(running) == 3:
                    break
                assert time.monotonic() < deadline, "Host scheduler did not start three eligible tasks"
                time.sleep(0.1)
            assert len(scheduled["tasks"]) == 4
            live_ids = {task["id"] for task in running}
            pause_project = envelope("pauseProject")
            pause_project["command"]["pauseProject"] = {"projectId": project_id}
            owner_command(pause_project)
            ceiling = envelope("setMaxConcurrentRuns")
            ceiling["command"]["setMaxConcurrentRuns"] = {"count": 1}
            owner_command(ceiling)
            time.sleep(1.1)
            assert {task["id"] for task in owner_snapshot()["tasks"] if task["state"]["status"] == "running"} == live_ids
            assert git("rev-parse", "HEAD") == head_before_start
            assert git("status", "--porcelain") == checkout_before_start
            with sqlite3.connect(database) as connection:
                assert connection.execute("SELECT COUNT(*) FROM run_spec").fetchone()[0] == 3
                assert connection.execute("SELECT COUNT(*) FROM effect WHERE status='pending'").fetchone()[0] >= 3
            owner_command(envelope("pauseAll"))
            repo.rename(moved)
            deadline = time.monotonic() + 8
            while owner_snapshot()["projects"][0]["availability"] != "missing":
                assert time.monotonic() < deadline, "Live folder observer did not mark missing"
                time.sleep(0.2)
        finally:
            try:
                owner.stdin.close()
            except BrokenPipeError:
                pass
            owner.wait(timeout=5)
            assert owner.returncode == 0, (owner.returncode, owner.stderr.read())
        assert run("snapshot")["projects"][0]["availability"] == "missing"
        relink = envelope("relinkProject")
        relink["command"]["relinkProject"] = {"projectId": project_id, "path": str(moved)}
        assert "ok" in send(relink)["result"]
        linked = run("snapshot")
        assert linked["projects"][0]["id"] == project_id and linked["projects"][0]["availability"] == "available"
        removal = envelope("removeProject")
        removal["command"]["removeProject"] = {"projectId": project_id}
        removed = send(removal)
        assert send(removal) == removed
        assert run("snapshot")["projects"] == [] and (moved / "tracked.txt").exists()
        detail = envelope("getTaskDetail")
        detail["command"]["getTaskDetail"] = {"taskId": task_id}
        archived = send(detail)["result"]["taskDetail"]["_0"]
        assert archived["task"]["state"]["status"] == "cancelled"
    print("Daemon/CLI smoke passed: wire sessions/replay/retention, real project/pipeline/live reload, bounded production scheduler/ceiling/pause/RunSpec, dirty checkout, relink/removal/history and single writer.")


if __name__ == "__main__":
    main()
