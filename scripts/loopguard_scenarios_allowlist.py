"""LG-6 — scenarios/ allowlist (spec §4.3, closes reviewer S3 + C-P4)."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

ALLOWED = {"e2e-feishu-cc.yaml", "e2e-esr-channel.yaml"}


def check(scenarios_dir: Path) -> list[str]:
    if not scenarios_dir.exists():
        return [f"{scenarios_dir}: directory missing"]
    violations: list[str] = []
    for p in scenarios_dir.iterdir():
        if p.is_dir():
            violations.append(f"unexpected subdirectory: {p.name}")
    present: set[str] = set()
    for p in scenarios_dir.rglob("*"):
        if p.is_file():
            rel = p.relative_to(scenarios_dir)
            present.add(str(rel))
    for missing in ALLOWED - present:
        violations.append(f"missing required file: {missing}")
    for extra in present - ALLOWED:
        violations.append(f"unexpected file (not in allowlist): {extra}")
    return violations


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--dir", required=True, type=Path)
    args = p.parse_args()

    v = check(args.dir)
    if v:
        print(f"LG-6 FAIL on {args.dir}:")
        for x in v:
            print(f"  {x}")
        return 1
    print(f"LG-6 PASS — {args.dir} contains exactly the allowed files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
