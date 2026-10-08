#!/usr/bin/env python3
"""Exercise FE-14 in the real WindowGroup with a private daemon and read-only CLI fixture."""
import argparse
import json
from pathlib import Path
import sqlite3
import subprocess
import tempfile

import importlib.util


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, default=Path("/tmp/kaban-fe14-app/Build/Products/Debug/Kaban.app"))
    args = parser.parse_args()
    executable = args.app.resolve() / "Contents/MacOS/Kaban"
    if not executable.is_file():
        parser.error("Build Kaban.app first")
    root = Path(tempfile.mkdtemp(prefix="kaban-fe14-", dir="/tmp"))
    repo = root / "repo"
    (repo / ".kaban/skills").mkdir(parents=True)
    spec = importlib.util.spec_from_file_location("pipeline_qa", Path(__file__).with_name("check-pipeline-editor.py"))
    source = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(source)
    (repo / ".kaban/pipeline.yaml").write_text(source.YAML)
    (repo / ".kaban/skills/dev.md").write_text("Model acceptance fixture.\n")
    for git_args in [["init", "-b", "main"], ["config", "user.name", "Model QA"],
                     ["config", "user.email", "model@example.test"], ["add", "."], ["commit", "-m", "Model QA source"]]:
        subprocess.run(["git", "-C", str(repo)] + git_args, check=True, capture_output=True)
    database = root / "store.sqlite"
    print(root, flush=True)

    def run(name, mode, theme="light", minimum=False, extra=()):
        command = [str(executable), "--developer", "--developer-database", str(database),
                   "--model-live-repository", str(repo), "--model-live-smoke", str(root / (name + ".json")),
                   "--qa-model-mode", mode, "--qa-theme", theme, "--export-live-window", str(root / (name + ".png")),
                   "--qa-pipeline-stage", "dev", "--qa-pipeline-section", "Исполнитель"]
        if minimum:
            command += ["--qa-size", "minimum"]
        with (root / (name + ".log")).open("w") as log:
            result = subprocess.run(command + list(extra), stdout=log, stderr=subprocess.STDOUT, timeout=90)
        report = json.loads((root / (name + ".json")).read_text())
        if result.returncode != 0 or report.get("result") != "passed":
            raise RuntimeError(f"{name}: {report}")
        print(name + ": passed", flush=True)

    run("empty-light-minimum", "bootstrap", minimum=True)
    models_file = root / "models.txt"
    rows = "explicit\tExplicit QA\ncomposer-qa\tComposer QA\ngpt-qa\tGPT QA\nunavailable-qa\tUnavailable QA\nauto\tAuto\n"
    models_file.write_text(rows)
    runner = root / "cursor-fixture"
    runner.write_text("#!/bin/sh\ncase \"$1\" in\n--version) echo 'model-qa 1' ;;\nstatus) echo 'Logged in' ;;\n--list-models) cat '" + str(models_file) + "' ;;\n*) echo 'Prompt invocation forbidden in model QA' >&2; exit 1 ;;\nesac\n")
    runner.chmod(0o755)
    with sqlite3.connect(database) as db:
        state = json.loads(db.execute("SELECT payload FROM runner_check WHERE id=1").fetchone()[0])
        state["executable"] = str(runner)
        db.execute("UPDATE runner_check SET payload=? WHERE id=1", (json.dumps(state).encode(),))
    run("commands-light", "flow")
    models_file.write_text(rows.replace("unavailable-qa\tUnavailable QA\n", ""))
    run("settings-light", "settings")
    run("settings-dark-minimum", "settings", theme="dark", minimum=True)
    run("picker-light", "picker", extra=("--qa-model-picker", "yes"))
    run("picker-unavailable-dark-minimum", "picker", theme="dark", minimum=True,
        extra=("--qa-model-picker", "yes", "--qa-model-query", "unavailable-qa"))
    run("unknown-dark-minimum", "unknown", theme="dark", minimum=True)
    run("override-dark-minimum", "override", theme="dark", minimum=True)
    def seed_decision(actual):
        with sqlite3.connect(database) as db:
            task_id, payload = db.execute("SELECT id, payload FROM task LIMIT 1").fetchone()
            task = json.loads(payload)
            state = {"status": "waiting_human", "reason": "model_substituted" if actual else "question"}
            task["card"].update(stageId="dev", model="explicit", state=state)
            task["machine"].update(stageId="dev", state=state)
            db.execute("UPDATE task SET payload=? WHERE id=?", (json.dumps(task).encode(), task_id))
            detail = json.loads(db.execute("SELECT payload FROM task_detail WHERE task_id=?", (task_id,)).fetchone()[0])
            run = {"id": "model-qa-run", "taskId": task_id, "stageId": "dev", "number": 1,
                   "status": "killed", "endReason": "model_substituted" if actual else "asked_human",
                   "requestedModel": "explicit", "countsTowardLimits": not actual,
                   "startedAt": task["card"]["updatedAt"], "endedAt": task["card"]["updatedAt"] + 1}
            if actual:
                run["actualModelName"] = "GPT QA"
            detail["runs"] = [run]
            detail["feed"] = [] if actual else [{"id": "model-unconfirmed", "at": run["startedAt"], "kind": "model_unconfirmed",
                                                "text": "Фактическое имя модели не подтверждено.", "runId": run["id"]}]
            db.execute("UPDATE task_detail SET payload=? WHERE task_id=?", (json.dumps(detail).encode(), task_id))
            inputs = json.loads(db.execute("SELECT payload FROM scheduler_inputs WHERE id=1").fetchone()[0])
            inputs["modelFlags"] = [flag for flag in inputs["modelFlags"] if flag["modelId"] != "explicit"]
            if actual:
                inputs["modelFlags"].append({"modelId": "explicit", "reason": "substituted", "requested": "Explicit QA",
                                             "actual": "GPT QA", "fallbackModel": "composer-qa", "since": run["endedAt"]})
            db.execute("UPDATE scheduler_inputs SET payload=? WHERE id=1", (json.dumps(inputs).encode(),))

    seed_decision(True)
    run("substitution-light", "decision")
    seed_decision(False)
    run("unconfirmed-dark-minimum", "unconfirmed", theme="dark", minimum=True)
    models_file.write_text("Error: Authentication required\n")
    run("refresh-error-light-minimum", "refresh-error", minimum=True)
    print("Private fixture and evidence retained at " + str(root), flush=True)


if __name__ == "__main__":
    main()
