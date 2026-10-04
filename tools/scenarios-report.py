#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Read-only scenario count, duplicate IDs, and JSON formatting report."""
import argparse
from collections import defaultdict
import json
from pathlib import Path
import sys


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", nargs="?", type=Path,
                        default=Path(__file__).resolve().parents[1] / "Scenarios/M1")
    parser.add_argument("--strict-format", action="store_true",
                        help="fail on indent/trailing-space/newline differences too")
    args = parser.parse_args()
    files = sorted(args.directory.glob("*.json"))
    if not files:
        parser.error("directory has no .json scenarios")
    ids = defaultdict(list)
    errors, formats, steps = [], [], 0
    for path in files:
        try:
            text = path.read_text(encoding="utf-8")
            root = json.loads(text, object_pairs_hook=unique_object)
            if not isinstance(root, dict) or not isinstance(root.get("id"), str) or not root["id"]:
                raise ValueError("nonempty id required")
            if not isinstance(root.get("steps"), list):
                raise ValueError("steps list required")
            ids[root["id"]].append(path.name)
            steps += len(root["steps"])
            issues = []
            if not text.endswith("\n"):
                issues.append("missing final newline")
            if any(line.rstrip() != line for line in text.splitlines()):
                issues.append("trailing whitespace")
            canonical = json.dumps(root, ensure_ascii=False, indent=2)
            if text.rstrip("\n") != canonical:
                issues.append("noncanonical 2-space JSON formatting")
            if issues:
                formats.append(f"{path.name}: {', '.join(issues)}")
        except (OSError, UnicodeError, ValueError) as error:
            errors.append(f"{path.name}: {error}")
    duplicates = {key: value for key, value in ids.items() if len(value) > 1}
    print(f"Scenarios: {len(files)} files, {len(ids)} unique IDs, {steps} steps")
    print(f"Duplicate IDs: {len(duplicates)}; parse/shape errors: {len(errors)}; formatting notices: {len(formats)}")
    for key, names in sorted(duplicates.items()):
        print(f"DUPLICATE {key}: {', '.join(names)}")
    for error in errors:
        print(f"ERROR {error}")
    for notice in formats:
        print(f"FORMAT {notice}")
    # Formatting is diagnostic by default: source generator owns normalization.
    return 1 if errors or duplicates or (args.strict_format and formats) else 0


if __name__ == "__main__":
    sys.exit(main())
