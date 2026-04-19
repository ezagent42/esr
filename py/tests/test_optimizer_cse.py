"""PRD 06 F06 — common-subexpression elimination on compose."""

from __future__ import annotations

import pytest

from esr.command import COMMAND_REGISTRY, command, compile_topology, compose, node, port


@pytest.fixture(autouse=True)
def _clear_registry() -> None:
    COMMAND_REGISTRY.clear()


def _pattern_a() -> None:
    """A → produces output port "mid" and owns node "shared-foo"."""
    port.input("from_src", "SrcMsg")
    port.output("mid", "MidMsg")
    node(id="shared-foo", actor_type="t", handler="h")


def _pattern_b() -> None:
    """B → consumes "mid" as input port, also owns "shared-foo"."""
    port.input("mid", "MidMsg")
    port.output("to_dst", "DstMsg")
    node(id="shared-foo", actor_type="t", handler="h")


def test_compose_serial_dedups_identical_nodes() -> None:
    """After compose.serial, a node id shared by A and B appears exactly once."""

    @command("composed")
    def build() -> None:
        compose.serial(_pattern_a, _pattern_b)

    topo = compile_topology("composed")
    ids = [n.id for n in topo.nodes]
    assert ids.count("shared-foo") == 1


def test_compose_serial_keeps_distinct_nodes_intact() -> None:
    """Nodes that don't collide are all preserved."""

    def a() -> None:
        port.input("src", "T")
        port.output("mid", "T")
        node(id="a1", actor_type="t", handler="h")

    def b() -> None:
        port.input("mid", "T")
        port.output("dst", "T")
        node(id="b1", actor_type="t", handler="h")

    @command("composed-distinct")
    def build() -> None:
        compose.serial(a, b)

    topo = compile_topology("composed-distinct")
    ids = {n.id for n in topo.nodes}
    assert ids == {"a1", "b1"}
