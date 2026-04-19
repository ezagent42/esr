"""PRD 06 F05 — dead-node elimination during compile."""

from __future__ import annotations

import pytest

from esr.command import COMMAND_REGISTRY, command, compile_topology, node, port


@pytest.fixture(autouse=True)
def _clear_registry() -> None:
    COMMAND_REGISTRY.clear()


def test_orphan_node_is_removed() -> None:
    """A node with no edges, no ports, no depends_on gets dropped."""

    @command("dead-orphan")
    def build() -> None:
        port.input("in", "T")
        port.output("out", "T")
        a = node(id="a", actor_type="t", handler="h")
        b = node(id="b", actor_type="t", handler="h")
        node(id="orphan", actor_type="t", handler="h")  # unreachable
        a >> b

    topo = compile_topology("dead-orphan")
    ids = {n.id for n in topo.nodes}
    assert "orphan" not in ids
    assert ids == {"a", "b"}


def test_single_node_is_not_considered_dead() -> None:
    """Single-node patterns (e.g. feishu-app-session) keep their node."""

    @command("single")
    def build() -> None:
        node(id="only", actor_type="t", handler="h")

    topo = compile_topology("single")
    assert len(topo.nodes) == 1
    assert topo.nodes[0].id == "only"


def test_node_referenced_only_via_depends_on_is_kept() -> None:
    """A node that is the target of depends_on but has no >> edges is kept."""

    @command("via-depends")
    def build() -> None:
        a = node(id="a", actor_type="t", handler="h")
        node(id="b", actor_type="t", handler="h", depends_on=[a.id])

    topo = compile_topology("via-depends")
    ids = {n.id for n in topo.nodes}
    assert ids == {"a", "b"}
