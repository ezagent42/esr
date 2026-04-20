"""Capabilities spec §3.1 — Python @handler(permissions=[...]) decoration."""

from __future__ import annotations

import pytest

from esr.handler import HANDLER_REGISTRY, all_permissions, handler
from esr.permissions import all_permissions as re_exported_all_permissions


@pytest.fixture(autouse=True)
def _clear_registry() -> None:
    """Keep each test isolated — the module-level registry is mutable."""
    HANDLER_REGISTRY.clear()


def test_handler_stores_permissions() -> None:
    @handler(actor_type="test_actor", name="test_action", permissions=["msg.send"])
    def h(state: object, event: object) -> tuple[object, list[object]]:
        return state, []

    entry = HANDLER_REGISTRY["test_actor.test_action"]
    assert entry.permissions == frozenset(["msg.send"])


def test_handler_without_permissions_has_empty_frozenset() -> None:
    @handler(actor_type="test_actor", name="no_perm")
    def h(state: object, event: object) -> tuple[object, list[object]]:
        return state, []

    entry = HANDLER_REGISTRY["test_actor.no_perm"]
    assert entry.permissions == frozenset()


def test_handler_permissions_dedup_via_frozenset() -> None:
    """Duplicate entries in the list collapse to a single frozenset member."""

    @handler(
        actor_type="test_actor",
        name="dedup",
        permissions=["msg.send", "msg.send", "session.create"],
    )
    def h(state: object, event: object) -> tuple[object, list[object]]:
        return state, []

    entry = HANDLER_REGISTRY["test_actor.dedup"]
    assert entry.permissions == frozenset(["msg.send", "session.create"])


def test_all_permissions_union() -> None:
    @handler(actor_type="a", name="x", permissions=["p1"])
    def h1(s: object, e: object) -> tuple[object, list[object]]:
        return s, []

    @handler(actor_type="b", name="y", permissions=["p1", "p2"])
    def h2(s: object, e: object) -> tuple[object, list[object]]:
        return s, []

    assert {"p1", "p2"}.issubset(all_permissions())


def test_all_permissions_empty_when_registry_empty() -> None:
    assert all_permissions() == frozenset()


def test_permissions_module_reexports_helper() -> None:
    """esr.permissions is the stable import path for IPC consumers."""
    assert re_exported_all_permissions is all_permissions


def test_permissions_kwarg_is_keyword_only() -> None:
    """All @handler args remain keyword-only, including permissions."""
    with pytest.raises(TypeError):
        handler("a", "b", ["p"])  # type: ignore[call-arg,misc]


def test_handler_entry_permissions_is_immutable() -> None:
    """HandlerEntry is frozen; entry.permissions stays a frozenset."""

    @handler(actor_type="t", name="n", permissions=["p"])
    def h(state: object, event: object) -> tuple[object, list[object]]:
        return state, []

    entry = HANDLER_REGISTRY["t.n"]
    assert isinstance(entry.permissions, frozenset)
    with pytest.raises(Exception):  # noqa: B017 — frozen dataclass
        entry.permissions = frozenset()  # type: ignore[misc]
