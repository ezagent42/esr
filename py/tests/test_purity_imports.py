"""PRD 02 F16 — purity check 1 (import allow-list)."""

from __future__ import annotations

from pathlib import Path

from esr.verify.purity import Violation, scan_imports


def _make_handler(tmp_path: Path, body: str) -> Path:
    """Write a fake handler module under ``tmp_path`` and return its path."""
    p = tmp_path / "handler_module.py"
    p.write_text(body)
    return p


def test_scan_imports_allow_list_clean(tmp_path: Path) -> None:
    """Imports inside the allow-list produce no violations."""
    path = _make_handler(
        tmp_path,
        """
from __future__ import annotations

from dataclasses import dataclass
from typing import Any
from enum import Enum

import esr
from pydantic import BaseModel


def handler(state, event):
    return state, []
""",
    )
    violations = scan_imports(path)
    assert violations == []


def test_scan_imports_flags_disallowed_module(tmp_path: Path) -> None:
    """An `import requests` triggers a violation with line number + module."""
    path = _make_handler(
        tmp_path,
        """
import requests  # line 2
def handler(state, event):
    return state, []
""",
    )
    violations = scan_imports(path)
    assert len(violations) == 1
    v = violations[0]
    assert isinstance(v, Violation)
    assert v.module == "requests"
    assert v.lineno == 2
    assert "not in allow-list" in v.message


def test_scan_imports_flags_from_import(tmp_path: Path) -> None:
    """`from aiohttp import ClientSession` also produces a violation."""
    path = _make_handler(
        tmp_path,
        "from aiohttp import ClientSession\n",
    )
    violations = scan_imports(path)
    assert len(violations) == 1
    assert violations[0].module == "aiohttp"


def test_scan_imports_accepts_extra_allowed(tmp_path: Path) -> None:
    """Callers may widen the allow-list via extra_allowed (e.g. esr.toml)."""
    path = _make_handler(tmp_path, "import requests\n")
    violations = scan_imports(path, extra_allowed={"requests"})
    assert violations == []


def test_scan_imports_allows_submodules_of_allow_list(tmp_path: Path) -> None:
    """`from typing.abc import ...` is allowed because top-level `typing` is."""
    path = _make_handler(
        tmp_path,
        "from esr.actions import Emit\nfrom esr.events import Event\n",
    )
    violations = scan_imports(path)
    assert violations == []


def test_scan_imports_rejects_submodule_of_disallowed(tmp_path: Path) -> None:
    """`import lark_oapi.api.v1` is rejected (its root `lark_oapi` isn't allowed)."""
    path = _make_handler(tmp_path, "from lark_oapi.api.v1 import something\n")
    violations = scan_imports(path)
    assert len(violations) == 1
    assert violations[0].module == "lark_oapi"
