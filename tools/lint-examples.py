#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Read-only YAML syntax/shape smoke; does not replace KabanKit validation."""
import argparse
from pathlib import Path
import sys

try:
    import yaml
except ImportError:
    sys.exit("PyYAML missing: install tools/requirements.txt into a project venv")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", nargs="?", type=Path,
                        default=Path(__file__).resolve().parents[1] / "examples/pipelines")
    args = parser.parse_args()
    files = sorted(args.directory.rglob("*.yaml"))
    if not files:
        parser.error("directory has no .yaml examples")
    failures = 0
    for path in files:
        label = path.relative_to(args.directory)
        try:
            root = yaml.safe_load(path.read_text(encoding="utf-8"))
            if not isinstance(root, dict):
                raise ValueError("root must be a mapping")
            if type(root.get("version")) is not int:
                raise ValueError("version must be present as integer")
            stages = root.get("stages")
            if not isinstance(stages, list) or not stages:
                raise ValueError("stages must be a nonempty list")
            for index, stage in enumerate(stages):
                if not isinstance(stage, dict):
                    raise ValueError(f"stages[{index}] must be a mapping")
                for key in ("id", "kind"):
                    if not isinstance(stage.get(key), str) or not stage[key]:
                        raise ValueError(f"stages[{index}].{key} required")
            # Negative examples deliberately omit models or break graphs/policy.
            negative = "invalid" in label.parts
            if not negative:
                for index, stage in enumerate(stages):
                    if stage["kind"] == "agent":
                        agent = stage.get("agent")
                        if not isinstance(agent, dict) or not isinstance(agent.get("model"), str) or not agent["model"].strip():
                            raise ValueError(f"stages[{index}].agent.model required")
            print(f"OK {label}: {len(stages)} stages" + (" (intentional semantic negative)" if negative else ""))
        except (OSError, UnicodeError, ValueError, yaml.YAMLError) as error:
            failures += 1
            print(f"FAIL {label}: {error}", file=sys.stderr)
    print(f"YAML smoke: {len(files)} files, {failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
