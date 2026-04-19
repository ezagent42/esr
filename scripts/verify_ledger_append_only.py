"""LG-7 — ledger append-only + evidence-type enum (spec §4.4, closes S2)."""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

APPROVED_EVIDENCE_TYPES = {
    "unit_tests", "prd_matrix", "loopguard", "scenario_mock",
    "final_gate_mock", "prd_acceptance", "ledger_check",
}


def _git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True, text=True, check=True,
    ).stdout


def check(repo: Path, ledger_rel: str) -> list[str]:
    violations: list[str] = []
    log = _git(repo, "log", "--pretty=format:%H", "--reverse", "--", ledger_rel).splitlines()
    prev_rows: list[str] = []
    for sha in log:
        try:
            body = _git(repo, "show", f"{sha}:{ledger_rel}")
        except subprocess.CalledProcessError:
            continue
        rows = [ln for ln in body.splitlines() if ln.startswith("| ")]
        if prev_rows:
            if len(rows) < len(prev_rows):
                violations.append(f"commit {sha[:7]}: row count decreased "
                                  f"({len(prev_rows)} -> {len(rows)}); removed/deletion")
            for i, (old, new) in enumerate(zip(prev_rows, rows)):
                if old != new:
                    violations.append(f"commit {sha[:7]}: row {i} edited in-place")
        for r in rows[len(prev_rows):]:
            parts = [p.strip() for p in r.strip("|").split("|")]
            if len(parts) < 7:
                continue
            ev_type = parts[5]
            if ev_type.startswith("---") or ev_type == "evidence-type":
                continue
            if ev_type not in APPROVED_EVIDENCE_TYPES:
                violations.append(f"commit {sha[:7]}: bad evidence-type {ev_type!r}")
        prev_rows = rows
    return violations


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--repo", type=Path, default=Path("."))
    p.add_argument("--ledger", default="docs/ralph-loop-ledger.md")
    args = p.parse_args()

    v = check(args.repo, args.ledger)
    if v:
        print("LG-7 FAIL:")
        for x in v:
            print(f"  {x}")
        return 1
    try:
        n = sum(1 for _ in _git(args.repo, "log", "--oneline", "--", args.ledger).splitlines())
    except subprocess.CalledProcessError:
        n = 0
    print(f"ledger integrity OK — {n} commits, 0 in-place edits")
    return 0


if __name__ == "__main__":
    sys.exit(main())
