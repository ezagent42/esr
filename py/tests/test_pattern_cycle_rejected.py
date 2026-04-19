"""PRD 06 F07 — depends_on cycle fails compile."""

from __future__ import annotations

import pytest

from esr.command import COMMAND_REGISTRY, command, compile_topology, node


@pytest.fixture(autouse=True)
def _clear_registry() -> None:
    COMMAND_REGISTRY.clear()


def test_cycle_in_depends_on_raises() -> None:
    """compile_topology raises ValueError when depends_on has a cycle."""

    @command("cyclic")
    def build() -> None:
        node(id="a", actor_type="t", handler="h", depends_on=["b"])
        node(id="b", actor_type="t", handler="h", depends_on=["a"])

    with pytest.raises(ValueError, match=r"cycle in depends_on"):
        compile_topology("cyclic")


def test_self_cycle_rejected() -> None:
    """A node depending on itself is a cycle."""

    @command("self-cycle")
    def build() -> None:
        node(id="a", actor_type="t", handler="h", depends_on=["a"])
        node(id="b", actor_type="t", handler="h", depends_on=["a"])

    with pytest.raises(ValueError, match=r"cycle in depends_on"):
        compile_topology("self-cycle")
