"""PRD 05 F10 / F11 — feishu_thread state + dedup bound."""

from __future__ import annotations

import pytest
from pydantic import ValidationError


def test_state_has_defaults() -> None:
    from esr_handler_feishu_thread.state import FeishuThreadState

    s = FeishuThreadState()
    assert s.thread_id == ""
    assert s.dedup == frozenset()
    assert s.ack_msg_id is None
    assert s.chat_id == ""


def test_state_is_frozen() -> None:
    from esr_handler_feishu_thread.state import FeishuThreadState

    s = FeishuThreadState()
    with pytest.raises(ValidationError):
        s.thread_id = "other"  # type: ignore[misc]


def test_with_added_dedup_adds() -> None:
    from esr_handler_feishu_thread.state import FeishuThreadState

    s = FeishuThreadState()
    s2 = s.with_added_dedup("m1")
    assert "m1" in s2.dedup
    assert s.dedup == frozenset()  # original unchanged


def test_dedup_bounded_to_1000() -> None:
    """Adding 1001 entries caps the set at 1000 — oldest gets dropped."""
    from esr_handler_feishu_thread.state import FeishuThreadState

    s = FeishuThreadState()
    for i in range(1001):
        s = s.with_added_dedup(f"m{i}")

    assert len(s.dedup) == 1000
    # The very first (oldest) is dropped; the newest remain
    assert "m0" not in s.dedup
    assert "m1000" in s.dedup


def test_with_chat_id() -> None:
    from esr_handler_feishu_thread.state import FeishuThreadState

    s = FeishuThreadState()
    s2 = s.with_chat_id("oc_abc")
    assert s2.chat_id == "oc_abc"
    assert s.chat_id == ""
