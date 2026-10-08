#!/usr/bin/env python3
"""Run the opt-in native FE-13 checks against a private repository and daemon."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile


YAML = """# preserve this comment
version: 1
future_extension: preserved
board: {max_waiting_human: 3, bounce_limit_total: 5, max_runs_per_task: 12}
git: {preset: standard, allow: [], deny: []}
workspace: {warm_paths: []}
stages:
  - id: backlog
    name: Backlog
    kind: queue
    on_success: dev
  - id: dev
    name: Dev
    kind: agent
    wip: 3
    agent: {harness: cursor-cli, model: explicit, skill: .kaban/skills/dev.md, permissions: write, mcp: [kaban]}
    retry: {max_attempts: 3, backoff: [30s, 2m]}
    timeouts: {stall: 10m, wall: 60m}
    on_success: review
  - {id: review, name: Human Review, kind: human, on_success: merge}
  - {id: merge, name: Merge, kind: merge, on_conflict: {stage: dev, limit: 2}, on_success: done}
  - {id: done, name: Done, kind: terminal}
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, default=Path("/tmp/kaban-context-app/Build/Products/Debug/Kaban.app"))
    args = parser.parse_args()
    executable = args.app.resolve() / "Contents/MacOS/Kaban"
    if not executable.is_file():
        parser.error("Build Kaban.app before running the native checks")
    root = Path(tempfile.mkdtemp(prefix="kaban-fe13-", dir="/tmp"))
    repo = root / "repo"
    (repo / ".kaban/skills").mkdir(parents=True)
    pipeline = repo / ".kaban/pipeline.yaml"
    pipeline.write_text(YAML)
    (repo / ".kaban/skills/dev.md").write_text("Implement acceptance criteria.\n")
    for git_args in [["init", "-b", "main"], ["config", "user.name", "Pipeline QA"],
                     ["config", "user.email", "pipeline@example.test"], ["add", "."], ["commit", "-m", "Initial QA source"]]:
        subprocess.run(["git", "-C", str(repo)] + git_args, check=True, capture_output=True)
    other = root / "other"
    subprocess.run(["git", "clone", "--local", str(repo), str(other)], check=True, capture_output=True)
    print(root, flush=True)

    def run(name, mode="capture", theme="light", minimum=False, extra=()):
        command = [str(executable), "--developer", "--developer-database", str(root / "store.sqlite"),
                   "--pipeline-live-repository", str(repo), "--pipeline-other-repository", str(other),
                   "--pipeline-live-smoke", str(root / (name + ".json")),
                   "--qa-pipeline-stage", "dev", "--qa-pipeline-mode", mode, "--qa-theme", theme,
                   "--export-live-window", str(root / (name + ".png"))]
        if minimum:
            command += ["--qa-size", "minimum"]
        command += list(extra)
        with (root / (name + ".log")).open("w") as log:
            completed = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=90)
        report = json.loads((root / (name + ".json")).read_text())
        if completed.returncode != 0 or report.get("result") != "passed":
            raise RuntimeError(f"{name}: {report}")
        print(f"{name}: passed", flush=True)

    run("apply-light", mode="apply")
    run("reopen-dark-minimum", mode="reopen", theme="dark", minimum=True)
    run("forms-light-minimum", minimum=True)
    run("executor-dark", theme="dark", extra=("--qa-pipeline-section", "Исполнитель"))
    run("yaml-dark-minimum", theme="dark", minimum=True, extra=("--qa-pipeline-yaml", "yes"))
    accepted = pipeline.read_text()
    pipeline.write_text("version: [\n")
    run("invalid-light-minimum", minimum=True)
    pipeline.write_text(accepted.replace('name: "Разработка 👋"', 'name: "' + "Длинное название " * 35 + '"'))
    run("long-dark-minimum", theme="dark", minimum=True)
    pipeline.unlink()
    run("absent-light-minimum", minimum=True)
    pipeline.write_text(accepted)
    print("Private fixture and evidence retained at " + str(root), flush=True)


if __name__ == "__main__":
    main()
