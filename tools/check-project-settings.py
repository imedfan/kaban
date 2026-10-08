#!/usr/bin/env python3
"""Check FE-15 in the real native window and a private, paused daemon."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, default=Path("/tmp/kaban-fe15-app/Build/Products/Debug/Kaban.app"))
    args = parser.parse_args()
    executable = args.app.resolve() / "Contents/MacOS/Kaban"
    if not executable.is_file():
        parser.error("Build Kaban.app first")
    root = Path(tempfile.mkdtemp(prefix="kaban-fe15-", dir="/tmp"))
    repo = root / "repo"
    (repo / ".kaban/skills").mkdir(parents=True)
    spec = importlib.util.spec_from_file_location("pipeline_qa", Path(__file__).with_name("check-pipeline-editor.py"))
    source = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(source)
    yaml = source.YAML.replace("workspace: {warm_paths: []}", "workspace:\n  warm_paths:\n    - node_modules # keep cache comment")
    yaml = yaml.replace("stages:\n", "suspicious_files: {patterns: ['*.pem'], max_file_mb: 5, allow: ['.env.example']}\nstages:\n", 1)
    (repo / ".kaban/pipeline.yaml").write_text(yaml)
    (repo / ".kaban/skills/dev.md").write_text("Settings acceptance fixture.\n")
    for command in [["init", "-b", "main"], ["config", "user.name", "Settings QA"],
                    ["config", "user.email", "settings@example.test"], ["add", "."], ["commit", "-m", "Settings QA source"]]:
        subprocess.run(["git", "-C", str(repo)] + command, check=True, capture_output=True)
    print(root, flush=True)

    def run(name, mode, theme="light", minimum=False, stage="__git", section="Git", preview=False):
        command = [str(executable), "--developer", "--developer-database", str(root / "store.sqlite"),
                   "--settings-live-repository", str(repo), "--settings-live-smoke", str(root / (name + ".json")),
                   "--qa-settings-mode", mode, "--qa-theme", theme, "--export-live-window", str(root / (name + ".png")),
                   "--qa-pipeline-stage", stage, "--qa-pipeline-section", section]
        if minimum:
            command += ["--qa-size", "minimum"]
        if preview:
            command += ["--qa-policy-preview", "yes"]
        with (root / (name + ".log")).open("w") as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=90)
        report = json.loads((root / (name + ".json")).read_text())
        if result.returncode != 0 or report.get("result") != "passed":
            raise RuntimeError(f"{name}: {report}")
        print(name + ": passed", flush=True)

    run("initial-metadata-light", "metadata")
    run("initial-resources-dark-minimum", "resources", theme="dark", minimum=True)
    run("commands-light", "flow")
    run("metadata-dark-minimum", "reopen", theme="dark", minimum=True)
    run("identity-refusal-light", "identity-refusal")
    run("resources-dark-minimum", "resources", theme="dark", minimum=True)
    run("long-identity-dark-minimum", "long-identity", theme="dark", minimum=True)
    run("git-project-light", "pipeline")
    run("git-project-dark-minimum", "pipeline", theme="dark", minimum=True)
    run("git-policy-dark-minimum", "pipeline", theme="dark", minimum=True, preview=True)
    run("workspace-light-minimum", "pipeline", minimum=True, stage="__workspace")
    run("files-dark-minimum", "pipeline", theme="dark", minimum=True, stage="__files")
    run("invalid-size-light-minimum", "invalid-size", minimum=True, stage="__files")
    run("disconnected-workspace-dark-minimum", "disconnected", theme="dark", minimum=True, stage="__workspace")
    run("stage-git-light", "pipeline", stage="dev")
    accepted = (repo / ".kaban/pipeline.yaml").read_text()
    readonly = accepted.replace("    on_success: review", "    on_success: ai_review", 1)
    readonly = readonly.replace("  - {id: review,", "  - id: ai_review\n    name: AI Review\n    kind: agent\n    agent: {harness: cursor-cli, model: explicit, skill: .kaban/skills/dev.md, permissions: read-only, workspace: fresh-readonly, mcp: [kaban]}\n    on_success: review\n  - {id: review,", 1)
    (repo / ".kaban/pipeline.yaml").write_text(readonly)
    run("readonly-stage-dark-minimum", "pipeline", theme="dark", minimum=True, stage="ai_review", preview=True)
    (repo / ".kaban/pipeline.yaml").write_text(accepted)
    (repo / ".kaban/pipeline.yaml").unlink()
    run("absent-files-light-minimum", "pipeline", minimum=True, stage="__files")
    (repo / ".kaban/pipeline.yaml").write_text(accepted)
    print("Private fixture and evidence retained at " + str(root), flush=True)


if __name__ == "__main__":
    main()
