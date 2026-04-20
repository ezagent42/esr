"""Adapter I/O-permission scan (PRD 02 F18; spec §5.4).

``scan_adapter(path, allowed_io) -> [Violation]`` walks the adapter
module at ``path`` and reports any top-level import whose root is not
in ``allowed_io`` (the dict passed to ``@esr.adapter``).

A small fixed set of stdlib modules and ``esr`` itself are always
allowed — adapters legitimately import ``asyncio``, ``json``,
``logging`` and so on, and forcing authors to declare those in every
manifest would only create noise. Non-stdlib imports *must* be
declared — that is the whole point of the ``allowed_io`` manifest.
"""

from __future__ import annotations

import ast
from pathlib import Path
from typing import Any

from esr.verify.purity import Violation

_ADAPTER_CORE_ALLOWED: frozenset[str] = frozenset(
    {
        # esr + stdlib that adapters may use unconditionally
        "esr",
        "__future__",
        "abc",
        "asyncio",
        "collections",
        "contextlib",
        "dataclasses",
        "datetime",
        "enum",
        "functools",
        "inspect",
        "io",
        "itertools",
        "json",
        "logging",
        "os",
        "pathlib",
        "re",
        "string",
        "sys",
        "time",
        "typing",
        "uuid",
        "warnings",
    }
)


def scan_adapter(path: Path, allowed_io: dict[str, Any]) -> list[Violation]:
    """Scan an adapter module for undeclared imports.

    ``allowed_io`` keys are the top-level module names the adapter is
    allowed to import (typically declared in ``@adapter(allowed_io=...)``).
    Values are version constraints (``"*"`` or a pin) — ignored here
    because at CI time we only check allow-list membership.
    """
    allowed = _ADAPTER_CORE_ALLOWED | set(allowed_io.keys())

    source = Path(path).read_text()
    tree = ast.parse(source, filename=str(path))

    violations: list[Violation] = []
    for stmt in ast.walk(tree):
        if isinstance(stmt, ast.Import):
            for alias in stmt.names:
                top = alias.name.split(".", 1)[0]
                if top not in allowed:
                    violations.append(
                        Violation(
                            module=top,
                            lineno=stmt.lineno,
                            message=(
                                f"import {alias.name!r} not in allowed_io "
                                f"(top-level {top!r}, declared: "
                                f"{sorted(allowed_io.keys())})"
                            ),
                        )
                    )
        elif isinstance(stmt, ast.ImportFrom):
            if stmt.module is None:
                continue
            top = stmt.module.split(".", 1)[0]
            if top not in allowed:
                violations.append(
                    Violation(
                        module=top,
                        lineno=stmt.lineno,
                        message=(
                            f"from {stmt.module!r} import ... not in allowed_io "
                            f"(top-level {top!r}, declared: "
                            f"{sorted(allowed_io.keys())})"
                        ),
                    )
                )
    return violations
