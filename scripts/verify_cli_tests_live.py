"""LG-9 + LG-10 — CLI tests must exercise live esrd (spec §4.3, closes M2 + C-P3)."""
from __future__ import annotations

import argparse
import ast
import sys
from pathlib import Path

ALLOWED_FIXTURES = {"esrd_fixture", "live_esrd"}


def _uses_allowed_fixture(func: ast.FunctionDef) -> bool:
    return any(arg.arg in ALLOWED_FIXTURES for arg in func.args.args)


def _has_submit_monkeypatch(func: ast.FunctionDef) -> list[str]:
    """Reviewer C-P3 fix: walk decorators + match any Call whose args (positional
    or keyword) contain `_submit_*` as a string literal or attribute reference."""
    hits: list[str] = []
    roots: list[ast.AST] = []
    roots.extend(func.decorator_list)
    roots.append(func)
    for root in roots:
        for node in ast.walk(root):
            if isinstance(node, ast.Call):
                for arg in node.args:
                    if isinstance(arg, ast.Constant) and isinstance(arg.value, str) \
                            and "_submit_" in arg.value:
                        hits.append(arg.value)
                    elif isinstance(arg, ast.Attribute):
                        unparsed = ast.unparse(arg)
                        if "_submit_" in unparsed:
                            hits.append(unparsed)
                for kw in node.keywords:
                    if isinstance(kw.value, ast.Constant) and isinstance(kw.value.value, str) \
                            and "_submit_" in kw.value.value:
                        hits.append(kw.value.value)
    return hits


def check_file(path: Path, no_monkeypatch: bool) -> list[str]:
    if not path.exists():
        return [f"{path}: missing"]
    tree = ast.parse(path.read_text())
    violations: list[str] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name.startswith("test_"):
            if not _uses_allowed_fixture(node):
                violations.append(f"{path}:{node.name} — missing esrd_fixture arg")
            if no_monkeypatch:
                hits = _has_submit_monkeypatch(node)
                for h in hits:
                    violations.append(f"{path}:{node.name} — monkeypatch of {h}")
    return violations


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--target", type=Path,
                   help="single file to check")
    p.add_argument("--no-monkeypatch", action="store_true")
    args = p.parse_args()

    targets: list[Path] = []
    if args.target:
        targets = [args.target]
    else:
        default = Path(__file__).resolve().parent.parent / "py/tests"
        targets = sorted(default.glob("test_cli_cmd_*.py"))

    violations: list[str] = []
    for t in targets:
        violations.extend(check_file(t, args.no_monkeypatch))

    if violations:
        print("LG-9/10 FAIL — CLI tests not exercising live esrd:")
        for v in violations:
            print(f"  {v}")
        return 1
    print(f"LG-9/10 PASS — {len(targets)} CLI test file(s) use live esrd")
    return 0


if __name__ == "__main__":
    sys.exit(main())
