"""Append a row to docs/ralph-loop-ledger.md (spec §4.4).

Closes reviewer S2: caller chooses an evidence-TYPE (enum); the script
maps it to a fixed command internally.
"""
from __future__ import annotations

import argparse
import hashlib
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

EVIDENCE_COMMANDS: dict[str, list[str]] = {
    "unit_tests": ["make", "test"],
    "prd_matrix": ["uv", "run", "python", "scripts/verify_prd_matrix.py"],
    "loopguard": ["bash", "scripts/loopguard.sh"],
    "scenario_mock": ["esr", "scenario", "run", "e2e-feishu-cc"],
    "final_gate_mock": ["bash", "scripts/final_gate.sh", "--mock"],
    "prd_acceptance": ["uv", "run", "python", "scripts/verify_prd_acceptance.py",
                       "--manifest", "docs/superpowers/prds/acceptance-manifest.yaml"],
    "ledger_check": ["uv", "run", "python", "scripts/verify_ledger_append_only.py"],
}


def _next_iter(ledger_path: Path) -> int:
    n = 0
    for ln in ledger_path.read_text().splitlines():
        if not ln.startswith("| "):
            continue
        parts = ln.split("|")
        if len(parts) < 2:
            continue
        try:
            n = max(n, int(parts[1].strip()))
        except ValueError:
            continue
    return n + 1


def _short_commit() -> str:
    r = subprocess.run(["git", "rev-parse", "--short", "HEAD"],
                       capture_output=True, text=True, check=True)
    return r.stdout.strip()


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--ledger", required=True, type=Path)
    p.add_argument("--phase", required=True)
    p.add_argument("--fr", required=True)
    p.add_argument("--evidence-type", required=True)
    p.add_argument("--dry-run", action="store_true",
                   help="skip running the mapped command; synth fake sha")
    args = p.parse_args()

    if args.evidence_type not in EVIDENCE_COMMANDS:
        print(f"bad evidence-type {args.evidence_type!r}; "
              f"enum allows {sorted(EVIDENCE_COMMANDS)}", file=sys.stderr)
        return 2

    if args.dry_run:
        sha = "sha256:" + hashlib.sha256(args.evidence_type.encode()).hexdigest()[:16]
        commit = "0000000"
    else:
        cmd = EVIDENCE_COMMANDS[args.evidence_type]
        r = subprocess.run(cmd, capture_output=True, text=True, check=False)
        if r.returncode != 0:
            print(f"evidence command failed: {' '.join(cmd)}", file=sys.stderr)
            print(r.stdout, r.stderr, file=sys.stderr)
            return 1
        sha = "sha256:" + hashlib.sha256(r.stdout.encode()).hexdigest()[:16]
        commit = _short_commit()

    n = _next_iter(args.ledger)
    date = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    row = f"| {n} | {date} | {args.phase} | {args.fr} | {commit} | {args.evidence_type} | {sha} |\n"
    with args.ledger.open("a") as f:
        f.write(row)
    print(f"appended iter {n} ({args.evidence_type})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
