"""PRD 02 F02 — Action dataclasses."""

from __future__ import annotations

import pytest

from esr.actions import Action, Emit, InvokeCommand, Route


def test_emit_is_frozen() -> None:
    """Emit is a frozen dataclass; mutation raises."""
    e = Emit(adapter="feishu-shared", action="react", args={"msg_id": "m1"})
    with pytest.raises(Exception):  # noqa: B017
        e.adapter = "other"  # type: ignore[misc]


def test_route_requires_target_and_msg() -> None:
    """Route without target + msg is a TypeError."""
    with pytest.raises(TypeError):
        Route()  # type: ignore[call-arg]


def test_invoke_command_stores_params_dict() -> None:
    ic = InvokeCommand(name="feishu-thread-session", params={"thread_id": "foo"})
    assert ic.name == "feishu-thread-session"
    assert ic.params == {"thread_id": "foo"}


def test_actions_equal_when_fields_equal() -> None:
    a = Emit(adapter="x", action="y", args={"z": 1})
    b = Emit(adapter="x", action="y", args={"z": 1})
    assert a == b


def test_action_type_alias_union() -> None:
    """Action type alias covers all three shapes."""
    items: list[Action] = [
        Emit(adapter="a", action="b", args={}),
        Route(target="cc:x", msg="hello"),
        InvokeCommand(name="p", params={}),
    ]
    assert len(items) == 3
