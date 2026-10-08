#!/usr/bin/env python3
"""Drive the native git permission UI against real, privately seeded MCP denials."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, default=Path("/tmp/kaban-fe17-app/Build/Products/Debug/Kaban.app"))
    parser.add_argument("--seed", type=Path, default=Path("/tmp/kaban-fe17-seed"))
    args = parser.parse_args()
    executable = args.app.resolve() / "Contents/MacOS/Kaban"
    if not executable.is_file() or not args.seed.is_file():
        parser.error("Build Kaban.app and tools/seed-git-permissions.swift first")
    root = Path(tempfile.mkdtemp(prefix="kaban-fe17-", dir="/tmp"))
    root.rmdir()
    subprocess.run([str(args.seed.resolve()), str(root)], check=True)
    print(root, flush=True)

    def run(name, mode, theme="light", minimum=False, escape=False):
        command = [str(executable), "-ApplePersistenceIgnoreState", "YES", "--developer",
                   "--developer-database", str(root / "store.sqlite"), "--git-live-smoke", str(root / (name + ".json")),
                   "--qa-git-mode", mode, "--qa-theme", theme, "--export-live-window", str(root / (name + ".png"))]
        if minimum:
            command += ["--qa-size", "minimum"]
        if escape:
            command += ["--qa-git-escape"]
        if mode in ["flow", "reopen", "created", "delivered", "consumed", "revoked", "expired", "disconnected"]:
            command += ["--qa-git-history", "yes"]
        log_path = root / (name + ".log")
        with log_path.open("w") as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=90)
        report_path = root / (name + ".json")
        if not report_path.is_file():
            raise RuntimeError(f"{name}: native QA produced no report; see {log_path}")
        report = json.loads(report_path.read_text())
        if result.returncode or report.get("result") != "passed":
            raise RuntimeError(f"{name}: {report}")
        print(name + ": passed", flush=True)

    run("allow-revoke-light", "flow")
    run("reopen-dark-minimum", "reopen", "dark", True)
    run("created-light", "created")
    run("empty-dark-minimum", "empty", "dark", True)
    run("delivered-light", "delivered")
    run("consumed-dark-minimum", "consumed", "dark", True)
    run("expired-light", "expired")
    run("hard-dark-minimum", "hard", "dark", True)
    run("unknown-light", "unknown")
    run("stale-light", "stale")
    run("long-dark-minimum", "long", "dark", True)
    run("preview-project-light", "preview-project")
    run("preview-stage-dark-minimum", "preview-stage", "dark", True)
    run("preview-escape-light", "preview-project", escape=True)
    run("policy-commit-light", "policy")
    run("retry-light", "retry")
    run("disconnected-dark-minimum", "disconnected", "dark", True)
    print("Private fixture and native evidence retained at " + str(root), flush=True)


if __name__ == "__main__":
    main()
