#!/usr/bin/env python3
"""Check working links, original design inputs, and preserved Drive sources."""

import hashlib
import json
from pathlib import Path
import re
import struct
import sys
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]
PRIMARY_DOCS = [
    "AGENTS.md", "README.md", "App/README.md", "design/README.md",
    "docs/README.md", "docs/current-state.md", "docs/contributing.md", "docs/getting-started.md",
    "docs/frontend-plan-v0.md", "docs/backend-plan-v0.md", "docs/architecture-v0.md",
    "docs/kaban-mvp-features-usecases.md", "docs/decisions-log.md",
    "docs/archive/README.md", "docs/team2/README.md", "docs/development/merge-order.md",
    "docs/acceptance-criteria-v0.md", "docs/research/README.md",
    "docs/research/kanban-factory-research.md", "docs/presentation/README.md", "tools/README.md",
]
PRIMARY_DOCS += [str(p.relative_to(ROOT)) for p in sorted((ROOT / "docs/frontend").glob("*.md"))]
PRIMARY_DOCS += [str(p.relative_to(ROOT)) for p in sorted((ROOT / "docs/design").glob("*.md"))]


def check():
    errors = []
    link_count = 0
    for name in PRIMARY_DOCS:
        path = ROOT / name
        if not path.is_file():
            errors.append("Missing working document: " + name)
            continue
        content = path.read_text(encoding="utf-8")
        # Examples in fenced code blocks are not document navigation links.
        content = re.sub(r"(?ms)^```[^\n]*\n.*?^```[^\n]*$", "", content)
        for match in re.finditer(r"\[[^\]\n]*\]\(([^)\n]+)\)", content):
            target = match.group(1).strip().strip("<>")
            url = urlsplit(target)
            if url.scheme or target.startswith("#"):
                continue
            resolved = (path.parent / unquote(url.path)).resolve()
            if not resolved.is_relative_to(ROOT):
                errors.append(name + ": link leaves repository: " + target)
            elif not resolved.exists():
                errors.append(name + ": broken local link: " + target)
            link_count += 1

    agents = ROOT / "AGENTS.md"
    if agents.is_file():
        size = agents.stat().st_size
        if size > 12 * 1024:
            errors.append("AGENTS.md exceeds the 12 KiB project guidance budget; route detail to focused documents")
        if (ROOT / "AGENTS.override.md").is_file():
            errors.append("Root AGENTS.override.md shadows the maintained AGENTS.md")

    manifest_path = ROOT / "design/manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        records = manifest["files"]
        if not isinstance(records, list) or not records:
            raise ValueError("files must be a nonempty list")
    except (OSError, ValueError, KeyError, TypeError) as exc:
        errors.append("Invalid design manifest: " + str(exc))
        records = []

    seen = set()
    png_count = 0
    for record in records:
        try:
            if not isinstance(record, dict):
                raise ValueError("asset record must be an object")
            relative = record["path"]
            path = (ROOT / relative).resolve()
            if not path.is_relative_to(ROOT / "design") or Path(relative).is_absolute():
                raise ValueError("asset path must be relative and inside design/")
            if relative in seen:
                raise ValueError("duplicate manifest path")
            seen.add(relative)
            data = path.read_bytes()
            if len(data) != record["bytes"] or hashlib.sha256(data).hexdigest() != record["sha256"]:
                raise ValueError("original bytes differ from the pinned SHA-256/size")
            if record["group"] == "reference-png":
                if data[:8] != b"\x89PNG\r\n\x1a\n" or len(data) < 24:
                    raise ValueError("invalid reference PNG")
                if list(struct.unpack(">II", data[16:24])) != record["pixels"]:
                    raise ValueError("reference PNG dimensions differ from manifest")
                png_count += 1
        except (OSError, ValueError, KeyError, TypeError) as exc:
            label = record.get("path", "<missing>") if isinstance(record, dict) else "<invalid>"
            errors.append("Design asset " + str(label) + ": " + str(exc))

    # All reference inputs must have provenance; working index and manifest are authored here.
    for path in sorted((ROOT / "design").rglob("*")):
        if not path.is_file() or path in {ROOT / "design/README.md", manifest_path}:
            continue
        if str(path.relative_to(ROOT)) not in seen:
            errors.append("Design file missing from manifest: " + str(path.relative_to(ROOT)))

    try:
        imported = json.loads((ROOT / "docs/drive-import-2026-10-05.json").read_text(encoding="utf-8"))["files"]
        if not isinstance(imported, list) or not imported:
            raise ValueError("files must be a nonempty list")
    except (OSError, ValueError, KeyError, TypeError) as exc:
        errors.append("Invalid Drive import manifest: " + str(exc))
        imported = []

    drive_ids = set()
    for record in imported:
        try:
            if not isinstance(record, dict):
                raise ValueError("import record must be an object")
            drive_id = record["drive_id"]
            if drive_id in drive_ids:
                raise ValueError("duplicate Drive file ID")
            drive_ids.add(drive_id)
            source = (ROOT / record["source_path"]).resolve()
            working = (ROOT / record["working_path"]).resolve()
            for relative, path in [(record["source_path"], source), (record["working_path"], working)]:
                if Path(relative).is_absolute() or not path.is_relative_to(ROOT / "docs"):
                    raise ValueError("import paths must be relative and inside docs/")
                if not path.is_file():
                    raise ValueError("missing local document: " + relative)
            if not source.is_relative_to(ROOT / "docs/archive/drive-2026-10-05"):
                raise ValueError("original must be an immutable Drive snapshot in docs/archive/drive-2026-10-05/")
            data = source.read_bytes()
            if len(data) != record["source_bytes"] or hashlib.sha256(data).hexdigest() != record["source_sha256"]:
                raise ValueError("original bytes differ from Drive SHA-256/size")
            parsed_url = urlsplit(record["drive_url"])
            if parsed_url.hostname not in {"drive.google.com", "docs.google.com"}:
                raise ValueError("provenance must use the canonical Drive URL")
        except (OSError, ValueError, KeyError, TypeError) as exc:
            label = record.get("title", "<missing>") if isinstance(record, dict) else "<invalid>"
            errors.append("Drive document " + str(label) + ": " + str(exc))

    if errors:
        for error in errors:
            print("ERROR: " + error, file=sys.stderr)
        return 1
    print("Context: {} working documents, {} local links; AGENTS.md {} bytes".format(
        len(PRIMARY_DOCS), link_count, agents.stat().st_size))
    print("Design: {} original files verified, {} reference PNGs".format(len(records), png_count))
    print("Drive: {} complete original documents verified; working paths exist in docs/".format(len(imported)))
    return 0


if __name__ == "__main__":
    sys.exit(check())
