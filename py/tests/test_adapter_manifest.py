"""PRD 04 F04 — adapter manifest (`esr.toml`)."""

from __future__ import annotations

import tomllib
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parents[2]

ADAPTERS = ("feishu",)


@pytest.mark.parametrize("name", ADAPTERS)
def test_manifest_parses(name: str) -> None:
    """The manifest is valid TOML."""
    path = _REPO_ROOT / "adapters" / name / "esr.toml"
    with path.open("rb") as f:
        tomllib.load(f)


@pytest.mark.parametrize("name", ADAPTERS)
def test_manifest_required_keys(name: str) -> None:
    """Every manifest declares the five keys esr-adapter-install reads."""
    path = _REPO_ROOT / "adapters" / name / "esr.toml"
    with path.open("rb") as f:
        data = tomllib.load(f)
    for key in ("name", "version", "module", "entry", "allowed_io"):
        assert key in data, f"{name}/esr.toml missing {key!r}"


@pytest.mark.parametrize("name", ADAPTERS)
def test_manifest_name_matches_dir(name: str) -> None:
    """manifest.name equals the directory name — keeps install wiring unambiguous."""
    path = _REPO_ROOT / "adapters" / name / "esr.toml"
    with path.open("rb") as f:
        data = tomllib.load(f)
    assert data["name"] == name


@pytest.mark.parametrize("name", ADAPTERS)
def test_manifest_module_points_to_existing_source(name: str) -> None:
    """manifest.module is a dotted path rooted at the adapter's src/ package."""
    path = _REPO_ROOT / "adapters" / name / "esr.toml"
    with path.open("rb") as f:
        data = tomllib.load(f)
    module = data["module"]
    # Module path is e.g. "esr_feishu.adapter" — root pkg must exist as src dir
    pkg_root = module.split(".", 1)[0]
    assert (_REPO_ROOT / "adapters" / name / "src" / pkg_root).is_dir()


@pytest.mark.parametrize("name", ADAPTERS)
def test_manifest_allowed_io_is_table(name: str) -> None:
    """allowed_io is a TOML table (dict) — not a scalar."""
    path = _REPO_ROOT / "adapters" / name / "esr.toml"
    with path.open("rb") as f:
        data = tomllib.load(f)
    assert isinstance(data["allowed_io"], dict)
    assert data["allowed_io"], f"{name}: allowed_io must declare at least one key"
