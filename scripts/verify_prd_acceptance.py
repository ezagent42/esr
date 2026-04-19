"""LG-3 + LG-5 — PRD acceptance section checks (spec §4.3).

Closes reviewer C3 (Acceptance-section-only regex scan) + S1 (normative manifest).
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import yaml

BAN_PATTERNS = [
    re.compile(r"\bdefer(red|s|ral|ring)?\b", re.I),
    re.compile(r"\bmanual step\b", re.I),
    re.compile(r"\bpost-install\b", re.I),
    re.compile(r"\bgated by\b", re.I),
    re.compile(r"\blive.*(hookup|integration|wiring)\b", re.I),
    re.compile(r"\bv0\.2\+?\b", re.I),
    re.compile(r"\btodo\b", re.I),
    re.compile(r"\bpending\b", re.I),
]

ACCEPTANCE_HEADING = re.compile(r"^##\s+Acceptance\s*$", re.M)
ANY_H2_HEADING = re.compile(r"^##\s+", re.M)


def extract_acceptance(md: str) -> str:
    m = ACCEPTANCE_HEADING.search(md)
    if not m:
        return ""
    start = m.end()
    tail = md[start:]
    n = ANY_H2_HEADING.search(tail)
    return tail[:n.start()] if n else tail


def check_manifest(prd_dir: Path, manifest_path: Path) -> list[str]:
    manifest = yaml.safe_load(manifest_path.read_text())
    violations: list[str] = []
    total = 0
    for key, rows in manifest.items():
        prd_num = key.removeprefix("prd_")
        candidates = list(prd_dir.glob(f"{prd_num}-*.md"))
        if not candidates:
            violations.append(f"{key}: no matching PRD file in {prd_dir}")
            continue
        body = candidates[0].read_text()
        acc = extract_acceptance(body)
        for row in rows:
            total += 1
            needle_ticked = f"[x] {row}"
            if needle_ticked in acc or needle_ticked.replace("[x]", "[X]") in acc:
                continue
            if f" {row}" in acc:
                violations.append(f"{key}: row present but not ticked — {row!r}")
            else:
                violations.append(f"{key}: missing — {row!r}")
    return violations if violations else [f"all {total} Acceptance items ticked"]


def check_regex_scan(prd_dir: Path) -> list[str]:
    violations: list[str] = []
    for md in sorted(prd_dir.glob("*.md")):
        acc = extract_acceptance(md.read_text())
        for pat in BAN_PATTERNS:
            for line in acc.splitlines():
                if pat.search(line):
                    violations.append(f"{md.name}: banned phrase in acceptance: {line.strip()!r}")
    return violations


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--prd-dir", type=Path,
                   default=Path(__file__).resolve().parent.parent / "docs/superpowers/prds")
    p.add_argument("--manifest", type=Path, help="acceptance-manifest.yaml")
    p.add_argument("--regex-scan", action="store_true",
                   help="LG-3: scan acceptance sections for banned phrases")
    args = p.parse_args()

    if args.regex_scan:
        v = check_regex_scan(args.prd_dir)
        if v:
            print("LG-3 FAIL — banned phrases in PRD acceptance:")
            for x in v:
                print(f"  {x}")
            return 1
        print("LG-3 PASS — no deferral phrases in any PRD acceptance")
        return 0

    if args.manifest:
        v = check_manifest(args.prd_dir, args.manifest)
        if len(v) == 1 and v[0].startswith("all "):
            print(f"LG-5 PASS — {v[0]}")
            return 0
        print("LG-5 FAIL — acceptance manifest mismatch:")
        for x in v:
            print(f"  {x}")
        return 1

    print("one of --manifest / --regex-scan is required", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
