"""PRD 06 F01 — feishu-app-session pattern compiles correctly."""

from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

from esr.command import COMMAND_REGISTRY, compile_topology

_REPO_ROOT = Path(__file__).resolve().parents[2]
_PATTERN_PATH = _REPO_ROOT / "patterns" / "feishu-app-session.py"


@pytest.fixture(autouse=True)
def _clean_registry_and_load() -> None:
    """Fresh COMMAND_REGISTRY around every test; re-load the pattern module."""
    COMMAND_REGISTRY.clear()
    spec = importlib.util.spec_from_file_location("_pattern_faas", _PATTERN_PATH)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)


def test_registered_in_command_registry() -> None:
    assert "feishu-app-session" in COMMAND_REGISTRY


def test_compiles_to_single_node_topology() -> None:
    topo = compile_topology("feishu-app-session")
    assert len(topo.nodes) == 1
    assert topo.edges == ()
    # Two template params declared (app_id + instance_name)
    assert "app_id" in topo.params
    assert "instance_name" in topo.params


def test_node_fields_match_spec() -> None:
    topo = compile_topology("feishu-app-session")
    n = topo.nodes[0]
    assert n.id == "feishu-app:{{app_id}}"
    assert n.actor_type == "feishu_app_proxy"
    assert n.adapter == "feishu-{{instance_name}}"
    assert n.handler == "feishu_app.on_msg"
    assert n.params == {"app_id": "{{app_id}}"}
