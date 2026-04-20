"""PRD 06 F03 / F04 — compiled YAML round-trip + byte determinism."""

from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest
import yaml

from esr.command import COMMAND_REGISTRY, compile_to_yaml, compile_topology

_REPO_ROOT = Path(__file__).resolve().parents[2]
_PATTERNS = ("feishu-app-session", "feishu-thread-session")


def _load_pattern(name: str) -> None:
    path = _REPO_ROOT / "patterns" / f"{name}.py"
    spec = importlib.util.spec_from_file_location(f"_pattern_{name}", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)


@pytest.fixture(autouse=True)
def _reset_registry() -> None:
    COMMAND_REGISTRY.clear()


# --- F03: YAML round-trip ---------------------------------------------


@pytest.mark.parametrize("pattern", _PATTERNS)
def test_yaml_round_trip(pattern: str, tmp_path: Path) -> None:
    """compile_topology → compile_to_yaml → parse → compare field-by-field."""
    _load_pattern(pattern)
    topo = compile_topology(pattern)
    path = tmp_path / f"{pattern}.yaml"
    compile_to_yaml(topo, path)

    data = yaml.safe_load(path.read_text())
    assert data["schema_version"] == 1
    assert data["name"] == topo.name
    assert data["params"] == list(topo.params)
    assert data["edges"] == [list(e) for e in topo.edges]
    assert len(data["nodes"]) == len(topo.nodes)

    # Node-level comparison: each compiled YAML node matches its Topology node
    for yaml_n, topo_n in zip(data["nodes"], topo.nodes, strict=True):
        assert yaml_n["id"] == topo_n.id
        assert yaml_n["actor_type"] == topo_n.actor_type
        assert yaml_n["handler"] == topo_n.handler
        if topo_n.adapter is not None:
            assert yaml_n["adapter"] == topo_n.adapter


# --- F04: byte-deterministic YAML -------------------------------------


@pytest.mark.parametrize("pattern", _PATTERNS)
def test_yaml_is_byte_deterministic(pattern: str, tmp_path: Path) -> None:
    """Compiling the same pattern twice produces identical YAML bytes."""
    _load_pattern(pattern)
    topo = compile_topology(pattern)

    a = tmp_path / "a.yaml"
    b = tmp_path / "b.yaml"
    compile_to_yaml(topo, a)
    compile_to_yaml(topo, b)
    assert a.read_bytes() == b.read_bytes()


def test_thread_session_init_directive_round_trips(tmp_path: Path) -> None:
    """init_directive on the tmux node survives YAML serialisation verbatim."""
    _load_pattern("feishu-thread-session")
    topo = compile_topology("feishu-thread-session")
    path = tmp_path / "out.yaml"
    compile_to_yaml(topo, path)
    data = yaml.safe_load(path.read_text())
    tmux_node = next(n for n in data["nodes"] if n["id"] == "tmux:{{thread_id}}")
    assert tmux_node["init_directive"] == {
        "action": "new_session",
        "args": {
            "session_name": "{{thread_id}}",
            "start_cmd": "scripts/esr-cc.sh",
            "env": {
                "ESR_WORKSPACE": "{{workspace}}",
                "ESR_SESSION_ID": "{{thread_id}}",
            },
        },
    }
