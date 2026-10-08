#!/usr/bin/env python3
"""Check FE-20 native settings with a private daemon and explicit producer fixtures."""
import argparse
import fcntl
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, default=Path("/tmp/kaban-fe20-app/Build/Products/Debug/Kaban.app"))
    parser.add_argument("--seed", type=Path, default=Path("/tmp/kaban-fe20-seed"))
    args = parser.parse_args()
    executable = args.app.resolve() / "Contents/MacOS/Kaban"
    if not executable.is_file() or not args.seed.is_file():
        parser.error("Build App and seed-mac-settings.swift first")
    root = Path(tempfile.mkdtemp(prefix="kaban-fe20-", dir="/tmp"))
    root.rmdir()
    subprocess.run([str(args.seed.resolve()), "seed", str(root)], check=True)
    print(root, flush=True)

    def run(name, mode, theme="light", minimum=False, bottom=False):
        command = [str(executable), "-ApplePersistenceIgnoreState", "YES", "--developer",
                   "--developer-database", str(root / "store.sqlite"), "--mac-live-smoke", str(root / (name + ".json")),
                   "--qa-mac-mode", mode, "--qa-theme", theme, "--export-live-window", str(root / (name + ".png"))]
        if minimum:
            command += ["--qa-size", "minimum"]
        if bottom:
            command += ["--qa-mac-scroll", "bottom"]
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

    run("commands-light", "flow")
    run("restart-dark-minimum", "restart", "dark", True)
    for mode in ["fresh", "unknown", "stale"]:
        subprocess.run([str(args.seed.resolve()), mode, str(root)], check=True)
        run(mode + "-light", mode, bottom=True)
        run(mode + "-dark-minimum", mode, "dark", True, True)
    subprocess.run([str(args.seed.resolve()), "flags", str(root)], check=True)
    run("flags-dark-minimum", "flags", "dark", True)
    run("offline-light", "offline")
    run("revoke-light", "revoke")
    run("revoked-restart-dark-minimum", "revoked-restart", "dark", True)
    print("Private fixture and evidence retained at " + str(root), flush=True)


if __name__ == "__main__":
    main()
