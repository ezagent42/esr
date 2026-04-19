"""Handler purity checks (PRD 02 F16, F17; spec §4.3).

Two static checks:

- **Import allow-list (F16):** ``scan_imports(path) -> [Violation]``
  walks a module's AST and flags any top-level import of a module
  outside the allow-list. The allow-list is deliberately small —
  core stdlib primitives + ``esr`` itself + ``pydantic``. Handlers
  can widen the list via ``esr.toml``'s ``allowed_imports`` field,
  which the caller passes in as ``extra_allowed``.

- **Frozen-state fixture (F17):** ``frozen_state_fixture(cls)`` —
  the pytest helper lives in this module so both checks are
  co-located. Implemented in PRD 02 F17.
"""

from __future__ import annotations

import ast
from dataclasses import dataclass
from pathlib import Path
from typing import Any, TypeVar

from pydantic import BaseModel

_CORE_ALLOWED: frozenset[str] = frozenset(
    {
        "esr",
        "typing",
        "dataclasses",
        "pydantic",
        "enum",
        "__future__",
    }
)


@dataclass(frozen=True)
class Violation:
    """A single violation surfaced by a purity/capability scan."""

    module: str
    lineno: int
    message: str


def scan_imports(path: Path, *, extra_allowed: set[str] | None = None) -> list[Violation]:
    """Return a list of import violations for the module at ``path``.

    The allow-list is the union of ``_CORE_ALLOWED`` and the optional
    ``extra_allowed`` set — typically the ``allowed_imports`` key from
    the handler's ``esr.toml``. Violations carry the top-level module
    name and the line number on which the offending import appears.
    """
    allowed = _CORE_ALLOWED | (extra_allowed or set())

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
                                f"import {alias.name!r} not in allow-list "
                                f"(top-level {top!r})"
                            ),
                        )
                    )
        elif isinstance(stmt, ast.ImportFrom):
            if stmt.module is None:
                continue  # `from . import foo` — skip
            top = stmt.module.split(".", 1)[0]
            if top not in allowed:
                violations.append(
                    Violation(
                        module=top,
                        lineno=stmt.lineno,
                        message=(
                            f"from {stmt.module!r} import ... not in allow-list "
                            f"(top-level {top!r})"
                        ),
                    )
                )
    return violations


# --- F17: frozen-state harness ------------------------------------------

M = TypeVar("M", bound=BaseModel)


def frozen_state_fixture(state_cls: type[M], **overrides: Any) -> M:
    """Construct a frozen pydantic state instance for unit-test use.

    The fixture exists to give handler unit tests a single entry
    point that (a) documents which state model is being exercised
    and (b) double-checks the model is actually frozen — a
    non-frozen model would silently allow mutations and defeat the
    purity guarantee.
    """
    cfg = getattr(state_cls, "model_config", None)
    frozen = (
        bool(cfg.get("frozen", False))
        if isinstance(cfg, dict)
        else bool(getattr(cfg, "frozen", False))
    )
    if not frozen:
        raise TypeError(
            f"{state_cls.__name__} must be frozen "
            "(set model_config['frozen'] = True)"
        )
    return state_cls(**overrides)
