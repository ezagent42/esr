"""PRD 06 F02 — feishu-thread-session pattern compiles correctly."""

from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

from esr.command import COMMAND_REGISTRY, compile_topology

_REPO_ROOT = Path(__file__).resolve().parents[2]
_PATTERN_PATH = _REPO_ROOT / "patterns" / "feishu-thread-session.py"


@pytest.fixture(autouse=True)
def _clean_registry_and_load() -> None:
    COMMAND_REGISTRY.clear()
    spec = importlib.util.spec_from_file_location("_pattern_fts", _PATTERN_PATH)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)


def test_registered() -> None:
    assert "feishu-thread-session" in COMMAND_REGISTRY


def test_compiles_to_three_node_topology() -> None:
    topo = compile_topology("feishu-thread-session")
    assert len(topo.nodes) == 3
    ids = [n.id for n in topo.nodes]
    assert ids == [
        "thread:{{thread_id}}",
        "tmux:{{thread_id}}",
        "cc:{{thread_id}}",
    ]


def test_edges_form_linear_chain() -> None:
    topo = compile_topology("feishu-thread-session")
    assert topo.edges == (
        ("thread:{{thread_id}}", "tmux:{{thread_id}}"),
        ("tmux:{{thread_id}}", "cc:{{thread_id}}"),
    )


def test_depends_on_dag_correct() -> None:
    topo = compile_topology("feishu-thread-session")
    by_id = {n.id: n for n in topo.nodes}
    assert by_id["thread:{{thread_id}}"].depends_on == ()
    assert by_id["tmux:{{thread_id}}"].depends_on == ("thread:{{thread_id}}",)
    assert by_id["cc:{{thread_id}}"].depends_on == ("tmux:{{thread_id}}",)


def test_init_directive_on_tmux_node() -> None:
    topo = compile_topology("feishu-thread-session")
    by_id = {n.id: n for n in topo.nodes}
    init = by_id["tmux:{{thread_id}}"].init_directive
    assert init is not None
    assert init["action"] == "new_session"
    assert init["args"]["session_name"] == "{{thread_id}}"
    assert init["args"]["start_cmd"] == "scripts/esr-cc.sh"


def test_params_includes_workspace_and_tag() -> None:
    topo = compile_topology("feishu-thread-session")
    assert set(topo.params) == {"thread_id", "chat_id", "workspace", "tag"}


def test_tmux_init_directive_has_env_workspace() -> None:
    topo = compile_topology("feishu-thread-session")
    by_id = {n.id: n for n in topo.nodes}
    tmux = by_id["tmux:{{thread_id}}"]
    assert tmux.init_directive["args"]["env"]["ESR_WORKSPACE"] == "{{workspace}}"
