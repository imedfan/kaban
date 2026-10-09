#!/usr/bin/env python3
"""Verify native suspicious-file decisions against real privately seeded Git checks."""
import argparse
import fcntl
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, default=Path("/tmp/kaban-fe18-app/Build/Products/Debug/Kaban.app"))
    parser.add_argument("--seed", type=Path, default=Path("/tmp/kaban-fe18-seed"))
    args = parser.parse_args()
    executable = args.app.resolve() / "Contents/MacOS/Kaban"
    if not executable.is_file() or not args.seed.is_file():
        parser.error("Build App and tools/seed-suspicious-files.swift first")
    root = Path(tempfile.mkdtemp(prefix="kaban-fe18-", dir="/tmp"))
    root.rmdir()
    with (root.parent / (root.name + "-seed.log")).open("w") as log:
        subprocess.run([str(args.seed.resolve()), str(root)], check=True, stdout=log, stderr=subprocess.STDOUT)
    print(root, flush=True)

    def run(name, mode, theme="light", minimum=False, submit=False, escape=False, bottom=False):
        command = [str(executable), "-ApplePersistenceIgnoreState", "YES", "--developer",
                   "--developer-database", str(root / "store.sqlite"), "--files-live-smoke", str(root / (name + ".json")),
                   "--qa-files-mode", mode, "--qa-theme", theme, "--export-live-window", str(root / (name + ".png"))]
        if minimum:
            command += ["--qa-size", "minimum"]
        if submit:
            command += ["--qa-files-submit", "yes"]
        if escape:
            command += ["--qa-files-escape", "yes"]
        if bottom:
            command += ["--qa-files-scroll", "bottom"]
        with (root / (name + ".log")).open("w") as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=90)
        report_path = root / (name + ".json")
        if not report_path.is_file():
            raise RuntimeError(f"{name}: report missing; see {root / (name + '.log')}")
        report = json.loads(report_path.read_text())
        if result.returncode or report.get("result") != "passed":
            raise RuntimeError(f"{name}: {report}")
        with (root / "store.sqlite.daemon.lock").open("rb") as lease:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(lease, fcntl.LOCK_UN)
        report["writerLeaseReleased"] = True
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print(name + ": passed", flush=True)

    run("stale-light", "stale")
    run("gate-empty-light", "gate-empty")
    run("gate-comment-dark-minimum", "gate-comment", "dark", True)
    run("merge-empty-dark-minimum", "merge-empty", "dark", True)
    run("merge-comment-light", "merge-comment")
    run("gate-escape-light", "gate-comment", escape=True)
    run("gate-return-accept-light", "gate-empty", submit=True)
    run("gate-return-comment-dark-minimum", "gate-comment", "dark", True, submit=True)
    run("merge-return-accept-dark-minimum", "merge-empty", "dark", True, submit=True)
    run("merge-return-comment-light", "merge-comment", submit=True)
    run("accept-light", "accept")
    run("reopen-dark-minimum", "reopen", "dark", True)
    run("long-dark-minimum", "long", "dark", True)
    run("missing-light", "missing")
    run("binary-light", "binary")
    run("finder-light", "finder")
    run("cursor-light", "cursor")
    run("agent-removal-dark-minimum", "agent", "dark", True)
    run("long-controls-dark-minimum", "long", "dark", True, bottom=True)
    run("exception-light", "exception")
    run("strict-dark-minimum", "strict", "dark", True)
    run("disconnected-dark-minimum", "disconnected", "dark", True)
    print("Private fixture and native evidence retained at " + str(root), flush=True)


if __name__ == "__main__":
    main()
