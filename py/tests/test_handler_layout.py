"""PRD 05 F01 / F02 — handler package layout + manifest."""

from __future__ import annotations

import tomllib
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parents[2]

HANDLERS = ("feishu_app", "feishu_thread", "cc_session")


@pytest.mark.parametrize("name", HANDLERS)
def test_handler_has_pyproject(name: str) -> None:
    assert (_REPO_ROOT / "handlers" / name / "pyproject.toml").exists()


@pytest.mark.parametrize("name", HANDLERS)
def test_handler_has_manifest(name: str) -> None:
    assert (_REPO_ROOT / "handlers" / name / "esr.toml").exists()


@pytest.mark.parametrize("name", HANDLERS)
def test_handler_has_source_package(name: str) -> None:
    pkg = _REPO_ROOT / "handlers" / name / "src" / f"esr_handler_{name}" / "__init__.py"
    assert pkg.exists()


@pytest.mark.parametrize("name", HANDLERS)
def test_handler_has_tests_dir(name: str) -> None:
    assert (_REPO_ROOT / "handlers" / name / "tests").is_dir()


# --- PRD 05 F02: manifest schema ---------------------------------------


@pytest.mark.parametrize("name", HANDLERS)
def test_manifest_parses(name: str) -> None:
    path = _REPO_ROOT / "handlers" / name / "esr.toml"
    with path.open("rb") as f:
        tomllib.load(f)


@pytest.mark.parametrize("name", HANDLERS)
def test_manifest_required_keys(name: str) -> None:
    path = _REPO_ROOT / "handlers" / name / "esr.toml"
    with path.open("rb") as f:
        data = tomllib.load(f)
    for key in ("name", "version", "module", "entry", "actor_type"):
        assert key in data, f"{name}/esr.toml missing {key!r}"


@pytest.mark.parametrize("name", HANDLERS)
def test_manifest_name_matches_dir(name: str) -> None:
    path = _REPO_ROOT / "handlers" / name / "esr.toml"
    with path.open("rb") as f:
        data = tomllib.load(f)
    assert data["name"] == name
