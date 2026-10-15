#!/usr/bin/env python3
"""Verify FE-32 in an ad-hoc native App using a private daemon and Git repos."""
import argparse
import fcntl
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="Ad-hoc Debug bundle with KABAN_QA")
    args = parser.parse_args()
    app = args.app.resolve()
    subprocess.run(["python3", str(Path(__file__).with_name("check-local-app-signing.py")), "--app", str(app)], check=True)
    for target in (app, app / "Contents/MacOS/KabanDaemon"):
        details = subprocess.run(["codesign", "-dv", str(target)], check=True, capture_output=True, text=True).stderr
        if "Signature=adhoc" not in details:
            parser.error("FE-32 requires ad-hoc signatures on App and helper")
    root = Path(tempfile.mkdtemp(prefix="kaban-fe32-", dir="/tmp"))
    repo = root / "Проект с длинным именем и пробелами"
    repo.mkdir()
    (repo / "README.md").write_text("Local client acceptance\n")
    for arguments in (["init", "-b", "main"], ["config", "user.name", "Local QA"],
                      ["config", "user.email", "local@example.test"], ["add", "."], ["commit", "-m", "Local acceptance"]):
        subprocess.run(["git", "-C", str(repo), *arguments], check=True, capture_output=True)
    relocated, recovered, clone = root / "relinked", root / "recovered", root / "clone"
    for destination in (relocated, clone):
        subprocess.run(["git", "clone", str(repo), str(destination)], check=True, capture_output=True)
    metadata = root / "project.json"
    print(root, flush=True)

    def run(name, theme, extra):
        report = root / (name + ".json")
        command = [str(app / "Contents/MacOS/Kaban"), "-ApplePersistenceIgnoreState", "YES", "--developer",
                   "--developer-database", str(root / "store.sqlite"), "--qa-task-suite", "kaban.qa.fe32." + root.name,
                   "--project-smoke", str(report), "--project-smoke-picker", "YES", "--qa-theme", theme,
                   "--qa-size", "minimum", "--export-live-window", str(root / (name + ".png")), *extra]
        with (root / (name + ".log")).open("w") as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=120)
        if not report.is_file():
            raise RuntimeError(f"{name}: no report; inspect {root / (name + '.log')}")
        values = json.loads(report.read_text())
        if result.returncode or values.get("result") != "passed":
            raise RuntimeError(f"{name}: {values}")
        with (root / "store.sqlite.daemon.lock").open("rb") as lease:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(lease, fcntl.LOCK_UN)
        values.update(configuration="Debug KABAN_QA", signing="ad-hoc", appSandbox=False, hardenedRuntime=True,
                      folderSelection="manual acceptance required; automation checks cancellation and entered paths",
                      transport="private stdio; actual bundled daemon", writerLeaseReleased=True)
        report.write_text(json.dumps(values, ensure_ascii=False, indent=2) + "\n")
        print(name + ": passed", flush=True)

    run("add-relink-light", "light", ["--project-smoke-repository", str(repo), "--project-smoke-relink", str(relocated),
                                        "--project-smoke-retain", str(metadata)])
    relocated.rename(recovered)
    run("restart-recover-dark", "dark", ["--project-smoke-reopen", str(metadata), "--project-smoke-relink", str(recovered),
                                          "--project-smoke-clone", str(clone)])
    print("Evidence: " + str(root), flush=True)


if __name__ == "__main__":
    main()
