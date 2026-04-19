"""PRD 06 F11 — param template lint."""

from __future__ import annotations

import pytest

from esr.command import COMMAND_REGISTRY, command, compile_topology, node, port


@pytest.fixture(autouse=True)
def _clear_registry() -> None:
    COMMAND_REGISTRY.clear()


def test_undeclared_template_fails_when_ports_used() -> None:
    """Using {{foo}} when foo isn't a declared port.input → compile error."""

    @command("bad-undeclared")
    def build() -> None:
        port.input("foo", "T")
        node(id="a", actor_type="t", handler="h", params={"x": "{{bar}}"})  # bar undeclared

    with pytest.raises(ValueError, match=r"template.*not declared|undeclared template"):
        compile_topology("bad-undeclared")


def test_unreferenced_port_is_allowed() -> None:
    """port.input in the EDSL doubles as a topology connection point —
    declaring one without a matching {{template}} reference is allowed
    (used for pattern API shaping). F11's reverse direction is
    intentionally skipped in v0.1 because of this dual-purpose role."""

    @command("unused-port-ok")
    def build() -> None:
        port.input("api_anchor", "T")  # topology entry point — no template needed
        node(id="a", actor_type="t", handler="h")
        node(id="b", actor_type="t", handler="h")

    # No raise
    topo = compile_topology("unused-port-ok")
    assert "api_anchor" in topo.ports_in


def test_patterns_without_ports_have_implicit_params() -> None:
    """feishu-app-session uses {{app_id}} / {{instance_name}} with no ports — valid."""

    @command("no-ports")
    def build() -> None:
        node(
            id="x:{{a}}",
            actor_type="t",
            handler="h",
            params={"foo": "{{b}}"},
        )

    # No raise — {{a}} and {{b}} become implicit params
    topo = compile_topology("no-ports")
    assert topo.params == ("a", "b")


def test_ports_fully_matched_compiles() -> None:
    """All declared port.inputs referenced and all templates declared → ok."""

    @command("matched")
    def build() -> None:
        port.input("foo", "T")
        port.input("bar", "T")
        node(id="a", actor_type="t", handler="h", params={"x": "{{foo}}", "y": "{{bar}}"})

    topo = compile_topology("matched")
    assert set(topo.params) == {"foo", "bar"}
