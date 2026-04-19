"""PRD 04 F07-F11 — feishu adapter directives."""

from __future__ import annotations

from esr.adapter import AdapterConfig


def _make_adapter() -> object:
    from esr_feishu.adapter import FeishuAdapter

    return FeishuAdapter.factory(
        "feishu-shared", AdapterConfig({"app_id": "cli_a", "app_secret": "s"})
    )


# --- F11: unknown action -----------------------------------------------


async def test_unknown_action_returns_error() -> None:
    """An action the adapter doesn't handle returns a clear error — no raise."""
    instance = _make_adapter()
    ack = await instance.on_directive("teleport", {})
    assert ack["ok"] is False
    assert "unknown action" in ack["error"]
    assert "teleport" in ack["error"]


async def test_unknown_action_adapter_still_alive() -> None:
    """After an unknown-action call the adapter accepts more directives."""
    instance = _make_adapter()
    ack1 = await instance.on_directive("teleport", {})
    ack2 = await instance.on_directive("teleport_again", {})
    assert ack1["ok"] is False
    assert ack2["ok"] is False
