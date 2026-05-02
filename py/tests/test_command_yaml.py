"""PRD 02 F14 — compile_to_yaml."""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

from esr.command import (
    COMMAND_REGISTRY,
    command,
    compile_to_yaml,
    compile_topology,
    node,
    port,
)


@pytest.fixture(autouse=True)
def _clear_registry() -> None:
    COMMAND_REGISTRY.clear()


def test_yaml_round_trip(tmp_path: Path) -> None:
    """compile → YAML → reload → matches."""

    @command("cmd-y")
    def build() -> None:
        # No port.input here — templates become implicit params.
        # (Patterns that use port.input MUST have every template name
        #  appear in the declared port list — see PRD 06 F11.)
        a = node(
            id="proxy",
            actor_type="feishu_thread",
            handler="on_msg",
            params={"app": "{{app_id}}"},
        )
        b = node(
            id="cc",
            actor_type="cc_session",
            handler="on_msg",
            adapter="cc_mcp",
            init_directive={"action": "new_session", "args": {"name": "{{thread_id}}"}},
        )
        a >> b

    topo = compile_topology("cmd-y")
    out = tmp_path / "cmd-y.yaml"
    compile_to_yaml(topo, out)

    data = yaml.safe_load(out.read_text())
    assert data["schema_version"] == 1
    assert data["name"] == "cmd-y"
    assert data["params"] == ["app_id", "thread_id"]
    assert data["ports"] == {"in": {}, "out": {}}
    assert data["edges"] == [["proxy", "cc"]]

    # init_directive round-trips intact
    cc_node = next(n for n in data["nodes"] if n["id"] == "cc")
    assert cc_node["init_directive"] == {
        "action": "new_session",
        "args": {"name": "{{thread_id}}"},
    }


def test_yaml_deterministic_key_order(tmp_path: Path) -> None:
    """YAML dumps with deterministic ordering so diffs stay stable."""

    @command("cmd-det")
    def build() -> None:
        port.input("in", "T")
        port.output("out", "T")
        node(id="z", actor_type="t", handler="on_msg")
        node(id="a", actor_type="t", handler="on_msg")

    topo = compile_topology("cmd-det")
    out1 = tmp_path / "a.yaml"
    out2 = tmp_path / "b.yaml"
    compile_to_yaml(topo, out1)
    compile_to_yaml(topo, out2)
    assert out1.read_text() == out2.read_text()


def test_yaml_node_omits_optional_empty_fields(tmp_path: Path) -> None:
    """Nodes without adapter / init_directive / depends_on should not
    have those keys in the YAML output — keeps diffs minimal."""

    @command("cmd-min")
    def build() -> None:
        port.input("in", "T")
        port.output("out", "T")
        node(id="n", actor_type="t", handler="on_msg")

    topo = compile_topology("cmd-min")
    out = tmp_path / "cmd-min.yaml"
    compile_to_yaml(topo, out)
    data = yaml.safe_load(out.read_text())
    n = data["nodes"][0]
    assert "adapter" not in n
    assert "init_directive" not in n
    assert "depends_on" not in n
    assert "params" not in n
