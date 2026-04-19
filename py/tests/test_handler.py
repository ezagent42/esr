"""PRD 02 F04 — @handler decorator."""

from __future__ import annotations

import pytest

from esr.handler import HANDLER_REGISTRY, handler


@pytest.fixture(autouse=True)
def _clear_registry() -> None:
    """Ensure each test starts with a clean HANDLER_REGISTRY."""
    HANDLER_REGISTRY.clear()


def test_handler_registers_under_key() -> None:
    """Decorated function is registered at f'{actor_type}.{name}'."""

    @handler(actor_type="feishu_app", name="on_msg")
    def on_msg(state: object, event: object) -> tuple[object, list[object]]:
        return state, []

    assert "feishu_app.on_msg" in HANDLER_REGISTRY
    entry = HANDLER_REGISTRY["feishu_app.on_msg"]
    assert entry.actor_type == "feishu_app"
    assert entry.name == "on_msg"
    assert entry.fn is on_msg


def test_handler_returns_original_callable() -> None:
    """Decorator returns the function unchanged so it can be called directly."""

    @handler(actor_type="cc_session", name="on_msg")
    def on_msg(state: int, event: int) -> tuple[int, list[object]]:
        return state + event, []

    new_state, actions = on_msg(1, 2)
    assert new_state == 3
    assert actions == []


def test_handler_duplicate_registration_raises() -> None:
    """Registering the same key twice raises ValueError with explicit key."""

    @handler(actor_type="feishu_thread", name="on_msg")
    def first(state: object, event: object) -> tuple[object, list[object]]:
        return state, []

    with pytest.raises(ValueError, match=r"handler feishu_thread\.on_msg already registered"):

        @handler(actor_type="feishu_thread", name="on_msg")
        def _second(state: object, event: object) -> tuple[object, list[object]]:
            return state, []


def test_handler_requires_keyword_args() -> None:
    """actor_type and name must be passed as keywords."""
    with pytest.raises(TypeError):
        handler("feishu_app", "on_msg")  # type: ignore[call-arg,misc]
