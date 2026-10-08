#!/usr/bin/env python3
"""Verify FE-19 against privately seeded production rollback and durable history."""
import argparse
import fcntl
import json
from pathlib import Path
import sqlite3
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, default=Path("/tmp/kaban-fe19-app/Build/Products/Debug/Kaban.app"))
    parser.add_argument("--seed", type=Path, default=Path("/tmp/kaban-fe19-seed"))
    args = parser.parse_args()
    executable = args.app.resolve() / "Contents/MacOS/Kaban"
    if not executable.is_file() or not args.seed.is_file():
        parser.error("Build App and seed-incidents.swift first")
    root = Path(tempfile.mkdtemp(prefix="kaban-fe19-", dir="/tmp"))
    root.rmdir()
    with (root.parent / (root.name + "-seed.log")).open("w") as log:
        subprocess.run([str(args.seed.resolve()), str(root)], check=True, stdout=log, stderr=subprocess.STDOUT)
    metadata = json.loads((root / "seed.json").read_text())
    with sqlite3.connect(root / "store.sqlite") as db:
        row = db.execute("SELECT payload FROM incident WHERE id = ?", (metadata["unknown"],)).fetchone()
        value = json.loads(row[0])
        value["kind"] = "future_protection_violation"
        db.execute("UPDATE incident SET payload = ? WHERE id = ?", (json.dumps(value).encode(), metadata["unknown"]))
    print(root, flush=True)

    def run(name, mode, theme="light", minimum=False, empty=False, bottom=False):
        database = root / ("empty.sqlite" if empty else "store.sqlite")
        command = [str(executable), "-ApplePersistenceIgnoreState", "YES", "--developer",
                   "--developer-database", str(database), "--incident-live-smoke", str(root / (name + ".json")),
                   "--qa-incident-mode", mode, "--qa-theme", theme, "--export-live-window", str(root / (name + ".png"))]
        if bottom:
            command += ["--qa-incident-scroll", "bottom"]
        if minimum:
            command += ["--qa-size", "minimum"]
        with (root / (name + ".log")).open("w") as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=90)
        report_path = root / (name + ".json")
        if not report_path.is_file():
            raise RuntimeError(f"{name}: report missing; see {root / (name + '.log')}")
        report = json.loads(report_path.read_text())
        if result.returncode or report.get("result") != "passed":
            raise RuntimeError(f"{name}: {report}")
        with Path(str(database) + ".daemon.lock").open("rb") as lease:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(lease, fcntl.LOCK_UN)
        report["writerLeaseReleased"] = True
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print(name + ": passed", flush=True)

    run("empty-light-minimum", "empty", minimum=True, empty=True)
    run("refs-light", "refs")
    run("tags-dark-minimum", "tags", "dark", True)
    run("config-light", "config")
    run("long-kaban-dark-minimum", "kaban", "dark", True)
    run("long-controls-dark-minimum", "kaban", "dark", True, bottom=True)
    run("foreign-light", "foreign")
    run("unknown-dark-minimum", "unknown", "dark", True)
    run("deleted-light", "deleted")
    run("hidden-dark-minimum", "hidden", "dark", True)
    run("missing-log-light", "missing-log")
    run("disconnected-cache-dark-minimum", "disconnected", "dark", True)
    run("policy-draft-light", "policy")
    run("model-without-resume-dark", "model", "dark")
    subprocess.run([str(args.seed.resolve()), "--discard-journal", str(root)], check=True, capture_output=True)
    run("retention-light-minimum", "retention", minimum=True)
    run("return-native-menu-dark-minimum", "return", "dark", True)
    subprocess.run([str(args.seed.resolve()), "--discard-journal", str(root)], check=True, capture_output=True)
    run("reopen-history-light", "reopen")
    print("Private fixture and native evidence retained at " + str(root), flush=True)


if __name__ == "__main__":
    main()
