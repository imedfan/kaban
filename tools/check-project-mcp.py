#!/usr/bin/env python3
"""Exercise MCP permissions and stage selection in the real native window."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sqlite3
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, default=Path("/tmp/kaban-fe16-app/Build/Products/Debug/Kaban.app"))
    args = parser.parse_args()
    executable = args.app.resolve() / "Contents/MacOS/Kaban"
    if not executable.is_file():
        parser.error("Build Kaban.app first")
    root = Path(tempfile.mkdtemp(prefix="kaban-fe16-", dir="/tmp"))
    spec = importlib.util.spec_from_file_location("pipeline_qa", Path(__file__).with_name("check-pipeline-editor.py"))
    source = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(source)
    yaml = source.YAML.replace("mcp: [kaban]", "mcp: [kaban, disabled], future_mcp: preserved", 1)
    yaml = "# preserve MCP source 👋\n" + yaml
    for name in ["repo", "other"]:
        repo = root / name
        (repo / ".kaban/skills").mkdir(parents=True)
        (repo / ".kaban/pipeline.yaml").write_text(yaml)
        (repo / ".kaban/skills/dev.md").write_text("MCP acceptance fixture.\n")
        for command in [["init", "-b", "main"], ["config", "user.name", "MCP QA"],
                        ["config", "user.email", "mcp@example.test"], ["add", "."], ["commit", "-m", "MCP QA source"]]:
            subprocess.run(["git", "-C", str(repo)] + command, check=True, capture_output=True)
        (repo / ".cursor").mkdir()
        (repo / ".cursor/mcp.json").write_text(json.dumps({"mcpServers": {
            "github": {"command": "unused-private-command", "args": ["private-secret"]},
            "shared": {"url": "https://project.invalid/private"}}}))
    personal = root / "personal/mcp.json"
    personal.parent.mkdir()
    personal.write_text(json.dumps({"mcpServers": {"shared": {"url": "https://personal.invalid/private"},
        "очень-длинное-имя-сервера-👋-" * 3: {"command": "unused-command"}}}))
    print(root, flush=True)

    def run(name, mode, theme="light", minimum=False):
        command = [str(executable), "-ApplePersistenceIgnoreState", "YES", "--developer", "--developer-database", str(root / "store.sqlite"),
                   "--mcp-live-repository", str(root / "repo"), "--mcp-other-repository", str(root / "other"),
                   "--mcp-live-smoke", str(root / (name + ".json")), "--qa-personal-mcp-config", str(personal),
                   "--qa-mcp-mode", mode, "--qa-theme", theme, "--export-live-window", str(root / (name + ".png")),
                   "--qa-pipeline-stage", "dev", "--qa-pipeline-section", "Исполнитель"]
        if minimum:
            command += ["--qa-size", "minimum"]
        with (root / (name + ".log")).open("w") as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=90)
        report = json.loads((root / (name + ".json")).read_text())
        if result.returncode != 0 or report.get("result") != "passed":
            raise RuntimeError(f"{name}: {report}")
        print(name + ": passed", flush=True)

    run("settings-light", "settings")
    run("permissions-light", "flow")
    run("restart-dark-minimum", "reopen", "dark", True)
    run("stage-light", "stage")
    run("stage-dark-minimum", "stage", "dark", True)
    run("apply-light", "apply")
    run("applied-settings-dark", "reopen", "dark")
    run("disconnected-stage-dark-minimum", "disconnected", "dark", True)
    valid = personal.read_bytes()
    personal.write_text("{broken-private-secret")
    run("read-error-light-minimum", "read-error", minimum=True)
    personal.write_bytes(valid)
    with sqlite3.connect(root / "store.sqlite") as database:
        for project_id, payload in database.execute("SELECT id,payload FROM project"):
            record = json.loads(payload)
            if record["summary"]["path"] == str(root / "repo"):
                record["production"]["unavailableReason"] = "mcp_unexpected"
                database.execute("UPDATE project SET payload=? WHERE id=?", (json.dumps(record).encode(), project_id))
                database.execute("INSERT INTO mcp_preflight(project_id,blocked,detail,warnings,config_json,kind) VALUES (?,1,'rogue','','{}','unexpected')", (project_id,))
    run("unexpected-settings-light", "unexpected")
    run("unexpected-board-dark-minimum", "unexpected-board", "dark", True)
    print("Private fixture and evidence retained at " + str(root), flush=True)


if __name__ == "__main__":
    main()
