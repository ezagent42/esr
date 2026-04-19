"""PRD 02 F04 / F05 / F06 — @handler + @handler_state + registry introspection."""

from __future__ import annotations

import pytest
from pydantic import BaseModel

from esr.handler import HANDLER_REGISTRY, STATE_REGISTRY, handler, handler_state


@pytest.fixture(autouse=True)
def _clear_registry() -> None:
    """Ensure each test starts with clean registries."""
    HANDLER_REGISTRY.clear()
    STATE_REGISTRY.clear()


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


# --- PRD 02 F05: @handler_state ----------------------------------------


def test_handler_state_registers_frozen_model() -> None:
    """Frozen pydantic model is registered under actor_type."""

    @handler_state(actor_type="feishu_app", schema_version=1)
    class FeishuAppState(BaseModel):
        model_config = {"frozen": True}
        thread_ids: tuple[str, ...] = ()

    assert "feishu_app" in STATE_REGISTRY
    entry = STATE_REGISTRY["feishu_app"]
    assert entry.actor_type == "feishu_app"
    assert entry.schema_version == 1
    assert entry.model is FeishuAppState


def test_handler_state_rejects_non_frozen_model() -> None:
    """A pydantic model without frozen=True is rejected at registration."""

    with pytest.raises(TypeError, match=r"must be frozen"):

        @handler_state(actor_type="bad_actor", schema_version=1)
        class _MutableState(BaseModel):
            counter: int = 0


def test_handler_state_duplicate_actor_type_raises() -> None:
    """One state model per actor_type; duplicate raises."""

    @handler_state(actor_type="feishu_thread", schema_version=1)
    class _First(BaseModel):
        model_config = {"frozen": True}

    with pytest.raises(ValueError, match=r"state for feishu_thread already registered"):

        @handler_state(actor_type="feishu_thread", schema_version=2)
        class _Second(BaseModel):
            model_config = {"frozen": True}


# --- PRD 02 F06: registry introspection --------------------------------


def test_handler_registry_clear() -> None:
    """Registries are plain dicts that can be cleared in tests."""

    @handler(actor_type="x", name="on")
    def _fn(state: object, event: object) -> tuple[object, list[object]]:
        return state, []

    assert HANDLER_REGISTRY  # non-empty
    HANDLER_REGISTRY.clear()
    assert HANDLER_REGISTRY == {}


def test_state_registry_clear() -> None:
    """STATE_REGISTRY is a plain dict that can be cleared in tests."""

    @handler_state(actor_type="y", schema_version=1)
    class _S(BaseModel):
        model_config = {"frozen": True}

    assert STATE_REGISTRY
    STATE_REGISTRY.clear()
    assert STATE_REGISTRY == {}


def test_handler_entry_is_frozen() -> None:
    """HandlerEntry is a frozen dataclass — mutation raises."""
    from esr.handler import HandlerEntry

    entry = HandlerEntry(actor_type="a", name="b", fn=lambda s, e: (s, []))
    with pytest.raises(Exception):  # noqa: B017
        entry.actor_type = "other"  # type: ignore[misc]


def test_state_entry_is_frozen() -> None:
    """StateEntry is a frozen dataclass — mutation raises."""
    from esr.handler import StateEntry

    class _M(BaseModel):
        model_config = {"frozen": True}

    entry = StateEntry(actor_type="a", schema_version=1, model=_M)
    with pytest.raises(Exception):  # noqa: B017
        entry.schema_version = 2  # type: ignore[misc]
