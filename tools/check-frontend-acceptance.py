#!/usr/bin/env python3
"""FE-22 repeatable automated acceptance. Never installs helpers or launches paid Cursor."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]


def facts(command):
    result = subprocess.run(command, cwd=REPO, capture_output=True, text=True, timeout=30)
    return {"exitCode": result.returncode, "stdout": result.stdout.strip(), "stderr": result.stderr.strip()}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_result(exit_code, timed_out, report=None, png=None):
    if timed_out:
        return "timed_out"
    if exit_code != 0:
        return "failed"
    if report is not None:
        try:
            if json.loads(report.read_text()).get("result") != "passed":
                return "failed"
        except (OSError, ValueError, AttributeError):
            return "failed"
    if png is not None:
        try:
            if not png.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"):
                return "failed"
        except OSError:
            return "failed"
    return "passed"


class Acceptance:
    def __init__(self, root, metadata):
        self.root = root
        self.data = {"environment": metadata, "steps": [], "liveAcceptance": "unverified",
                     "visualInspection": "manual_required", "accessibility": "manual_required"}
        self.save()

    def save(self):
        self.data["result"] = ("automated_failed_live_unverified" if any(
            step["result"] != "passed" for step in self.data["steps"]
        ) else "automated_passed_live_unverified" if "finishedUnix" in self.data else "running")
        temporary = self.root / "summary.tmp"
        temporary.write_text(json.dumps(self.data, ensure_ascii=False, indent=2) + "\n")
        temporary.replace(self.root / "summary.json")

    def run(self, name, command, scope, report=None, png=None, timeout=120, env=None):
        started = time.time()
        log = self.root / (name + ".log")
        timed_out = False
        launch_error = None
        # Each run owns a fresh directory, so an old report cannot turn a failed
        # launch green. Kill only this process group on timeout (including helper).
        with log.open("w") as output:
            try:
                process = subprocess.Popen([str(arg) for arg in command], cwd=REPO, stdout=output,
                                           stderr=subprocess.STDOUT, start_new_session=True, env=env)
                try:
                    code = process.wait(timeout=timeout)
                except subprocess.TimeoutExpired:
                    timed_out = True
                    os.killpg(process.pid, signal.SIGKILL)
                    code = process.wait()
            except OSError as error:
                launch_error = str(error)
                output.write(launch_error + "\n")
                code = 127
        step = {"name": name, "scope": scope, "command": [str(arg) for arg in command],
                "startedUnix": started, "elapsedSeconds": time.time() - started,
                "exitCode": code, "result": validate_result(code, timed_out, report, png), "log": str(log)}
        if launch_error:
            step["launchError"] = launch_error
        for label, path in (("report", report), ("png", png)):
            if path is not None:
                step[label] = str(path)
        if report is not None and report.is_file():
            try:
                step["details"] = json.loads(report.read_text())
            except ValueError:
                pass
        self.data["steps"].append(step)
        self.save()
        print(f'{name}: {step["result"]}', flush=True)
        return step["result"] == "passed"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="Built ad-hoc Debug bundle with KABAN_QA")
    parser.add_argument("--release-app", type=Path, required=True, help="Built ad-hoc production Release bundle")
    parser.add_argument("--bin-dir", type=Path, required=True, help="swift build --show-bin-path")
    parser.add_argument("--output", type=Path, help="New evidence directory; must not exist")
    parser.add_argument("--core-tests", action="store_true", help="Also run complete Swift suites with M1 scenarios")
    args = parser.parse_args()
    args.app, args.release_app, args.bin_dir = args.app.resolve(), args.release_app.resolve(), args.bin_dir.resolve()
    products = [app / "Contents/MacOS" / name for app in (args.app, args.release_app)
                for name in ("Kaban", "KabanDaemon", "KabanGitShim")]
    products += [args.bin_dir / name for name in ("KabanDaemon", "kabanctl", "KabanGitShim")]
    if not all(path.is_file() for path in products):
        parser.error("Build Debug, Release and SwiftPM executables first")
    if args.output:
        root = args.output.resolve()
        root.mkdir(parents=True, exist_ok=False)
    else:
        root = Path(tempfile.mkdtemp(prefix="kaban-fe22-", dir="/tmp"))
    print(root, flush=True)
    metadata = {"sourceHeadObserved": facts(["git", "rev-parse", "HEAD"]),
                "sourceStatus": facts(["git", "status", "--short"]),
                "sourceDiffSHA256": hashlib.sha256(subprocess.check_output(["git", "diff", "HEAD"], cwd=REPO)).hexdigest(),
                "macOS": facts(["sw_vers"]), "hardware": facts(["sysctl", "hw.model", "hw.memsize"]),
                "swift": facts(["swift", "--version"]), "xcode": facts(["xcodebuild", "-version"]),
                "architecture": platform.machine(), "python": sys.version,
                "productSHA256": {str(path): digest(path) for path in products},
                "buildProvenance": "prebuilt products; source HEAD is observation, not proof of build origin",
                "cursor": "synthetic CLI only; no paid starts or user credentials",
                "coreTests": "requested" if args.core_tests else "not_run"}
    qa = Acceptance(root, metadata)
    py = sys.executable
    qa.run("context", [py, "tools/check-project-context.py"], "documents and design originals")
    if args.core_tests:
        qa.run("core-tests", ["swift", "test"], "unit/integration; M1 state-machine scenarios",
               timeout=1800, env={**os.environ, "KABAN_SCENARIOS": "Scenarios/M1"})
    ready = True
    for label, app in (("debug", args.app), ("release", args.release_app)):
        ready &= qa.run(label + "-signing", [py, "tools/check-local-app-signing.py", "--app", app], "ad-hoc signature/runtime/no App Sandbox")
        ready &= qa.run(label + "-contents", [py, "tools/check-app-build-contents.py", "--app", app] + (["--qa"] if label == "debug" else []), "Mach-O production/QA separation")
    qa.run("transport", [py, "tools/smoke-daemon-transport.py", "--bin-dir", args.bin_dir], "private stdio daemon and CLI", timeout=300)
    qa.run("shim", [py, "tools/check-git-shim.py", "--shim", args.app / "Contents/MacOS/KabanGitShim"], "real git shim; synthetic HTTP server")
    qa.data["nativeAcceptance"] = "running" if ready else "blocked_by_product_checks"
    if ready:
        executable = args.app / "Contents/MacOS/Kaban"

        def native(name, flag, extra=(), theme="light", capture=False, suite=None):
            report = root / (name + ".json")
            png = root / (name + ".png") if capture else None
            command = [executable, "-ApplePersistenceIgnoreState", "YES", flag, report,
                       "--qa-theme", theme, "--qa-board-suite", suite or "kaban.qa.fe22." + root.name + "." + name,
                       "--qa-task-suite", "kaban.qa.fe22." + root.name + "." + name, *extra]
            if png:
                command += ["--export-live-window", png]
            qa.run(name, command, "mock DTO transport; actual WindowGroup", report, png, timeout=150)

        for theme in ("light", "dark"):
            for name, flag, extra in (
                ("ui", "--ui-smoke", []), ("controls", "--control-smoke", []),
                ("details", "--detail-smoke", ["--qa-detail", "summary"]),
                ("log", "--log-smoke", ["--qa-log", "summary"]),
                ("answer", "--answer-smoke", ["--qa-answer", "question"]),
                ("review", "--review-smoke", ["--qa-review", "summary"]),
                ("merge", "--merge-smoke", ["--qa-merge", "limit"]),
            ):
                native(name + "-" + theme, flag, extra, theme)
            for state in ("minimum", "long", "empty", "error", "connection-error", "grouped", "reduce-motion"):
                png = root / ("board-" + state + "-" + theme + ".png")
                qa.run(png.stem, [executable, "-ApplePersistenceIgnoreState", "YES", "--qa-board", "matrix",
                    "--qa-state", state, "--qa-size", "minimum", "--qa-theme", theme,
                    "--qa-reduce-motion", "yes" if state == "reduce-motion" else "no",
                    "--export-live-window", png], "mock DTOs; actual WindowGroup capture, visual review required", png=png)
            for profile in ("5x50", "10x500"):
                native("load-" + profile + "-" + theme, "--board-load-smoke", ["--qa-load-profile", profile], theme, True)
        suite = "kaban.qa.fe22." + root.name + ".restart"
        for mode in ("seed", "verify"):
            native("board-restart-" + mode, "--board-smoke", ["--qa-board", "matrix", "--qa-board-restart", mode], suite=suite)
        native("log-volume", "--log-volume-smoke", ["--qa-log", "volume"])
        for name, script, extra in (
            ("cursor-settings", "check-cursor-setup.py", []),
            ("pipeline", "check-pipeline-editor.py", []),
            ("diagnostics", "check-pipeline-editor.py", ["--validation-messages"]),
            ("models", "check-model-settings.py", []),
        ):
            qa.run(name, [py, "tools/" + script, "--app", args.app, *extra], "private stdio daemon; synthetic CLI/fixtures, actual WindowGroup", timeout=1200)
        qa.data["nativeAcceptance"] = "completed_with_results_below"
    qa.data["finishedUnix"] = time.time()
    qa.save()
    print("Evidence: " + str(root / "summary.json"), flush=True)
    return 0 if all(step["result"] == "passed" for step in qa.data["steps"]) else 1


if __name__ == "__main__":
    sys.exit(main())
