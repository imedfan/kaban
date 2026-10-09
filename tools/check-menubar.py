#!/usr/bin/env python3
"""Check FE-21 window lifetime and notification routes through a private daemon."""
import argparse
import fcntl
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, default=Path("/tmp/kaban-fe21-app/Build/Products/Debug/Kaban.app"))
    parser.add_argument("--seed", type=Path, default=Path("/tmp/kaban-fe21-seed"))
    parser.add_argument("--theme", choices=["light", "dark"], default="light")
    parser.add_argument("--minimum", action="store_true")
    args = parser.parse_args()
    executable = args.app.resolve() / "Contents/MacOS/Kaban"
    if not executable.is_file() or not args.seed.is_file():
        parser.error("Build App and seed-human-answers.swift first")
    root = Path(tempfile.mkdtemp(prefix="kaban-fe21-", dir="/tmp")); root.rmdir()
    subprocess.run([str(args.seed.resolve()), str(root)], check=True)
    print(root, flush=True)
    command = [str(executable), "-ApplePersistenceIgnoreState", "YES", "--developer",
               "--developer-database", str(root / "store.sqlite"), "--qa-task-suite", "kaban.qa.fe21." + root.name,
               "--menubar-live-smoke", str(root / "result.json"), "--qa-theme", args.theme,
               "--export-live-window", str(root / "window.png")]
    if args.minimum:
        command += ["--qa-size", "minimum"]
    with (root / "app.log").open("w") as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=120)
    report = json.loads((root / "result.json").read_text())
    if result.returncode or report.get("result") != "passed":
        raise RuntimeError(str(report))
    with (root / "store.sqlite.daemon.lock").open("rb") as lease:
        fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(lease, fcntl.LOCK_UN)
    report["writerLeaseReleased"] = True
    (root / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
