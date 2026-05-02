"""PRD 04 F01 — adapter package layout.

Every adapter ships as a standalone Python distribution at
``adapters/<name>/`` with four mandatory pieces:

- ``pyproject.toml``
- ``src/esr_<name>/__init__.py``
- ``esr.toml`` (installable manifest — PRD 04 F04)
- ``tests/``

This test asserts the layout structurally for the in-tree adapters
``feishu`` and ``cc_mcp``. The actual adapter implementations are
checked by their own per-FR tests (F05+).
"""

from __future__ import annotations

from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parents[2]  # py/tests/..  →  repo root

ADAPTERS = ("feishu", "cc_mcp")


@pytest.mark.parametrize("name", ADAPTERS)
def test_adapter_has_pyproject(name: str) -> None:
    p = _REPO_ROOT / "adapters" / name / "pyproject.toml"
    assert p.exists(), f"missing {p}"


@pytest.mark.parametrize("name", ADAPTERS)
def test_adapter_has_manifest(name: str) -> None:
    p = _REPO_ROOT / "adapters" / name / "esr.toml"
    assert p.exists(), f"missing {p}"


@pytest.mark.parametrize("name", ADAPTERS)
def test_adapter_has_source_package(name: str) -> None:
    p = _REPO_ROOT / "adapters" / name / "src" / f"esr_{name}" / "__init__.py"
    assert p.exists(), f"missing {p}"


@pytest.mark.parametrize("name", ADAPTERS)
def test_adapter_has_tests_dir(name: str) -> None:
    p = _REPO_ROOT / "adapters" / name / "tests"
    assert p.is_dir(), f"missing {p}"
