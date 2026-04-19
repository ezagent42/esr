"""PRD 05 F06 — feishu_app state model."""

from __future__ import annotations

import pytest
from pydantic import ValidationError


def test_state_has_defaults() -> None:
    from esr_handler_feishu_app.state import FeishuAppState

    s = FeishuAppState()
    assert s.app_id == ""
    assert s.bound_threads == frozenset()


def test_state_equality_by_value() -> None:
    from esr_handler_feishu_app.state import FeishuAppState

    a = FeishuAppState(app_id="cli_a", bound_threads=frozenset({"foo"}))
    b = FeishuAppState(app_id="cli_a", bound_threads=frozenset({"foo"}))
    assert a == b


def test_state_is_frozen() -> None:
    from esr_handler_feishu_app.state import FeishuAppState

    s = FeishuAppState()
    with pytest.raises(ValidationError):
        s.app_id = "other"  # type: ignore[misc]


def test_with_added_thread_returns_new_state() -> None:
    from esr_handler_feishu_app.state import FeishuAppState

    s = FeishuAppState(app_id="cli_a")
    s2 = s.with_added_thread("foo")
    assert s2.bound_threads == frozenset({"foo"})
    # original unchanged
    assert s.bound_threads == frozenset()
    # fluent: further adds stack
    assert s2.with_added_thread("bar").bound_threads == frozenset({"foo", "bar"})
