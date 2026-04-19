"""PRD 02 F12 — compose.serial."""

from __future__ import annotations

import pytest

from esr.command import COMMAND_REGISTRY, _command_context, compose, node, port


@pytest.fixture(autouse=True)
def _clear_registry() -> None:
    COMMAND_REGISTRY.clear()


def _pattern_a() -> None:
    """A pattern: input 'from_src' → node 'mid' → output 'to_core'."""
    port.input("from_src", "SrcMsg")
    port.output("to_core", "CoreMsg")
    node(id="a_mid", actor_type="proxy", handler="on_msg")


def _pattern_b() -> None:
    """A pattern: input 'to_core' → node 'b_mid' → output 'to_dst'."""
    port.input("to_core", "CoreMsg")
    port.output("to_dst", "DstMsg")
    node(id="b_mid", actor_type="proxy", handler="on_msg")


def test_serial_with_shared_port() -> None:
    """A's output 'to_core' matches B's input 'to_core' — becomes internal."""
    with _command_context("cmd") as ctx:
        compose.serial(_pattern_a, _pattern_b)

    # "to_core" shared → removed from top-level in both directions
    assert "to_core" not in ctx.ports_in
    assert "to_core" not in ctx.ports_out
    # Unshared top-level ports remain
    assert ctx.ports_in == {"from_src": "SrcMsg"}
    assert ctx.ports_out == {"to_dst": "DstMsg"}
    # Both patterns' nodes merged into outer
    assert {n.id for n in ctx.nodes} == {"a_mid", "b_mid"}


def test_serial_type_mismatch_raises() -> None:
    """Shared port name with different types raises TypeError."""

    def pattern_mismatch_b() -> None:
        port.input("to_core", "WrongType")  # different from A's CoreMsg
        port.output("to_dst", "DstMsg")

    with _command_context("cmd"), pytest.raises(TypeError, match=r"port to_core type mismatch"):
        compose.serial(_pattern_a, pattern_mismatch_b)


def test_serial_no_shared_port_raises() -> None:
    """Patterns with disjoint port names — not a valid serial composition."""

    def disjoint_b() -> None:
        port.input("completely_different", "T")
        port.output("to_dst", "DstMsg")

    with _command_context("cmd"), pytest.raises(ValueError, match=r"no shared port"):
        compose.serial(_pattern_a, disjoint_b)


def test_serial_outside_context_raises() -> None:
    """compose.serial outside a command context raises."""
    with pytest.raises(RuntimeError, match=r"compose\.serial.*outside"):
        compose.serial(_pattern_a, _pattern_b)
