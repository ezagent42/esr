"""LG-1 — scenario YAML structure + live-signature enforcement (spec §4.2).

Closes reviewer S4 (blocking signature check) and C-P1 (literal-substring
match instead of regex-against-regex, + reject defanging alternations).
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import yaml

ALLOWED_TOP_KEYS = {"name", "description", "mode", "setup", "steps", "teardown"}
REQUIRED_STEP_KEYS = {"id", "description", "command", "expect_stdout_match",
                      "expect_exit", "timeout_sec"}
BANNED_KEYS = {"covered_by", "unit_tests", "deferred", "skip", "todo"}

DEFANG_PATTERNS = [
    re.compile(r"\|\s*\.[\*\+]"),
    re.compile(r"\|\s*\(?\.[\*\+]"),
    re.compile(r"^\^?\.[\*\+]\$?$"),
    re.compile(r"\(\?:\.[\*\+]\)"),
]


def _load_signatures(path: Path) -> list[str]:
    return [line.strip()
            for line in path.read_text().splitlines()
            if line.strip() and not line.startswith("#")]


def _scan_banned_keys(node: object, trail: str = "") -> list[str]:
    hits: list[str] = []
    if isinstance(node, dict):
        for k, v in node.items():
            if str(k) in BANNED_KEYS:
                hits.append(f"{trail}/{k}")
            hits.extend(_scan_banned_keys(v, f"{trail}/{k}"))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            hits.extend(_scan_banned_keys(v, f"{trail}[{i}]"))
    return hits


def _check_signature(step_regex: str, sigs: list[str]) -> tuple[bool, str]:
    for dp in DEFANG_PATTERNS:
        if dp.search(step_regex):
            return False, f"defanging universal-match found: {dp.pattern!r}"
    for sig in sigs:
        if sig in step_regex:
            return True, f"contains signature substring: {sig!r}"
    return False, "no approved signature substring present"


def check(scenario_path: Path, sigs_path: Path) -> list[str]:
    data = yaml.safe_load(scenario_path.read_text()) or {}
    if not isinstance(data, dict):
        return [f"{scenario_path}: top-level must be a mapping"]
    violations: list[str] = []

    extra = set(data.keys()) - ALLOWED_TOP_KEYS
    if extra:
        violations.append(f"extra top-level keys: {sorted(extra)}")

    banned = _scan_banned_keys(data)
    if banned:
        violations.extend(f"banned key at {t}" for t in banned)

    sigs = _load_signatures(sigs_path)
    for i, step in enumerate(data.get("steps") or []):
        if not isinstance(step, dict):
            violations.append(f"step[{i}]: not a mapping")
            continue
        missing = REQUIRED_STEP_KEYS - set(step.keys())
        if "expect_stdout_match" in missing and step.get("live_signature") == "exempt":
            if not step.get("reason"):
                violations.append(f"step[{i}]: exempt without reason")
            continue
        if missing:
            violations.append(f"step[{i}]: missing keys {sorted(missing)}")
            continue
        ok, why = _check_signature(step["expect_stdout_match"], sigs)
        if not ok:
            violations.append(
                f"step[{i}] id={step.get('id')}: {why} "
                f"(got: {step['expect_stdout_match']!r})"
            )
    return violations


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--scenario", required=True, type=Path)
    p.add_argument("--signatures", required=True, type=Path)
    args = p.parse_args()

    v = check(args.scenario, args.signatures)
    if v:
        print(f"LG-1 FAIL on {args.scenario}:")
        for hit in v:
            print(f"  {hit}")
        return 1
    print(f"LG-1 PASS — {args.scenario} well-formed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
