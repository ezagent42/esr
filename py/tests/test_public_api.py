"""ESR Python SDK public API surface.

The original assertion list (PRD 02 F19) included the topology DSL
names `command`, `node`, `port`, `compose`. Those were removed
2026-05-06 along with the P3-13-deleted `Esr.Topology` runtime;
sessions are spawned via slash commands now. Surface narrowed to
the handler/adapter SDK + message shapes.
"""

from __future__ import annotations


def test_all_public_names_importable() -> None:
    """Every name promised by the public SDK surface is importable from the top-level package."""
    import esr

    expected = {
        "handler",
        "handler_state",
        "adapter",
        "AdapterConfig",
        "Emit",
        "Route",
        "InvokeCommand",
        "Event",
        "Directive",
        "EsrURI",
    }
    missing = {name for name in expected if not hasattr(esr, name)}
    assert missing == set()


def test_version_exposed() -> None:
    """esr.__version__ is a non-empty string."""
    import esr

    assert isinstance(esr.__version__, str)
    assert esr.__version__


def test_emit_flows_through_top_level() -> None:
    """Constructing an Emit via `esr.Emit(...)` works identically to the submodule."""
    from esr import Emit
    from esr.actions import Emit as SubEmit

    assert Emit is SubEmit


def test_handler_registration_via_public_api() -> None:
    """@esr.handler registers into the same HANDLER_REGISTRY as the submodule."""
    import esr
    from esr.handler import HANDLER_REGISTRY

    HANDLER_REGISTRY.clear()

    @esr.handler(actor_type="a", name="b")
    def fn(state: object, event: object) -> tuple[object, list[object]]:
        return state, []

    assert "a.b" in HANDLER_REGISTRY
