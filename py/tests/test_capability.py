"""PRD 02 F18 — capability scan for adapters."""

from __future__ import annotations

from pathlib import Path

from esr.verify.capability import scan_adapter


def _make_adapter(tmp_path: Path, body: str) -> Path:
    p = tmp_path / "adapter_module.py"
    p.write_text(body)
    return p


def test_scan_adapter_allows_declared_root(tmp_path: Path) -> None:
    """`from lark_oapi.api.im.v1 import ...` passes when lark_oapi is declared."""
    path = _make_adapter(
        tmp_path,
        "from lark_oapi.api.im.v1 import ReactionClient\nimport lark_oapi\n",
    )
    violations = scan_adapter(path, allowed_io={"lark_oapi": "*"})
    assert violations == []


def test_scan_adapter_flags_undeclared_import(tmp_path: Path) -> None:
    """`import requests` without declaring `requests` produces a violation."""
    path = _make_adapter(tmp_path, "import requests\n")
    violations = scan_adapter(path, allowed_io={})
    assert len(violations) == 1
    v = violations[0]
    assert v.module == "requests"
    assert "not in allowed_io" in v.message


def test_scan_adapter_allows_core_stdlib(tmp_path: Path) -> None:
    """Stdlib modules used commonly in adapters are always allowed."""
    path = _make_adapter(
        tmp_path,
        """
import asyncio
import json
import logging
from pathlib import Path
from typing import Any

from esr.adapter import adapter, AdapterConfig
""",
    )
    violations = scan_adapter(path, allowed_io={})
    assert violations == []


def test_scan_adapter_multiple_violations(tmp_path: Path) -> None:
    """All undeclared imports surface as separate violations with line numbers."""
    path = _make_adapter(
        tmp_path,
        """
import requests  # line 2
from httpx import Client  # line 3
import aiohttp  # line 4
""",
    )
    violations = scan_adapter(path, allowed_io={"aiohttp": "*"})
    # aiohttp allowed; requests + httpx violations
    mods = sorted(v.module for v in violations)
    assert mods == ["httpx", "requests"]
