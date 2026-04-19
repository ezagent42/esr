"""LG-2 — AST non-empty-body check (spec §4.3, closes reviewer C1 + C-P2).

Usage:
    verify_entry_bodies.py [--target <file>:<function>]  # check one
    verify_entry_bodies.py                                # check default manifest

Exit 0 on clean; 1 if any function has a stub body.
"""
from __future__ import annotations

import argparse
import ast
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

DEFAULT_MANIFEST: list[tuple[str, list[str]]] = [
    ("py/src/esr/ipc/adapter_runner.py", ["run"]),
    ("py/src/esr/ipc/handler_worker.py", ["run"]),
    ("py/src/esr/cli/main.py", [
        "_submit_cmd_run", "_submit_cmd_stop", "_submit_actors",
        "_submit_trace", "_stream_telemetry", "_submit_debug",
        "_submit_deadletter", "_submit_drain",
    ]),
    ("py/src/esr/cli/runtime_bridge.py", ["connect", "call", "push_event"]),
]

STUB_ERROR_SENTINELS = {"not yet wired", "not implemented", "stub", "deferred"}
LOGGER_METHODS = {"debug", "info", "warn", "warning", "error", "critical", "log"}


def _is_cheap_stmt(stmt: ast.stmt) -> bool:
    """True if the statement contributes no real runtime work."""
    if isinstance(stmt, (ast.Pass, ast.Import, ast.ImportFrom)):
        return True
    if isinstance(stmt, ast.Expr):
        val = stmt.value
        if isinstance(val, ast.Constant):
            return True
        if isinstance(val, ast.Call):
            fn = val.func
            if isinstance(fn, ast.Attribute) and fn.attr.lower() in LOGGER_METHODS:
                return True
            if isinstance(fn, ast.Name) and fn.id == "print":
                return True
        return False
    if isinstance(stmt, ast.Assign) and isinstance(stmt.value, ast.Constant):
        return True
    if isinstance(stmt, ast.Assign) and isinstance(stmt.value, ast.Call):
        fn = stmt.value.func
        if isinstance(fn, ast.Attribute) and fn.attr in {"getLogger", "get_logger"}:
            return True
        if isinstance(fn, ast.Name) and fn.id == "getLogger":
            return True
    if isinstance(stmt, ast.Return):
        v = stmt.value
        if v is None or isinstance(v, (ast.Constant, ast.List, ast.Tuple, ast.Set, ast.Dict)):
            return True
    if isinstance(stmt, ast.Raise):
        return True
    return False


def _is_stub_body(func: ast.AsyncFunctionDef | ast.FunctionDef) -> tuple[bool, str]:
    body = func.body
    if body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant) \
            and isinstance(body[0].value.value, str):
        body = body[1:]
    if not body:
        return True, "empty body"
    for stmt in body:
        if isinstance(stmt, ast.Raise):
            exc = stmt.exc
            if isinstance(exc, ast.Call) and isinstance(exc.func, ast.Name) \
                    and exc.func.id == "NotImplementedError":
                return True, "raises NotImplementedError"
        if isinstance(stmt, ast.Return) and isinstance(stmt.value, ast.Dict):
            for k, v in zip(stmt.value.keys, stmt.value.values):
                if isinstance(k, ast.Constant) and k.value == "error" \
                        and isinstance(v, ast.Constant) \
                        and any(s in str(v.value).lower() for s in STUB_ERROR_SENTINELS):
                    return True, f"stub dict return: error={v.value!r}"
    if all(_is_cheap_stmt(s) for s in body):
        return True, f"body of {len(body)} statement(s) is entirely cheap/trivial (no real work)"
    return False, ""


def check_file(path: Path, function_names: list[str]) -> list[str]:
    if not path.exists():
        return [f"{path}: file missing"]
    tree = ast.parse(path.read_text())
    found: dict[str, ast.AsyncFunctionDef | ast.FunctionDef] = {}
    for node in ast.walk(tree):
        if isinstance(node, (ast.AsyncFunctionDef, ast.FunctionDef)):
            found[node.name] = node
    violations: list[str] = []
    for name in function_names:
        if name not in found:
            violations.append(f"{path}:{name} — function not found")
            continue
        stub, reason = _is_stub_body(found[name])
        if stub:
            violations.append(f"{path}:{name} — {reason}")
    return violations


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--target", help="single target as FILE:FUNC (for tests)")
    args = p.parse_args()

    violations: list[str] = []
    if args.target:
        file_str, _, func = args.target.partition(":")
        path = Path(file_str) if Path(file_str).is_absolute() else REPO_ROOT / file_str
        violations.extend(check_file(path, [func]))
    else:
        for rel, funcs in DEFAULT_MANIFEST:
            violations.extend(check_file(REPO_ROOT / rel, funcs))

    if violations:
        print("LG-2 FAIL — stub / empty bodies detected:")
        for v in violations:
            print(f"  {v}")
        return 1
    print("LG-2 PASS — all entry bodies non-trivial")
    return 0


if __name__ == "__main__":
    sys.exit(main())
