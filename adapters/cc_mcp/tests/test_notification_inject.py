"""PR-9 T11b.4b: cc_mcp must emit `notifications/claude/channel` frames
Claude Code can route into conversation context.

Validates:
1. `_handle_inbound` with kind="notification" writes a SessionMessage
   whose wrapped JSONRPCNotification method is exactly
   "notifications/claude/channel" (Claude Code's channel listener
   doesn't dispatch on anything else).
2. The frame params carry `content` (the inner text of the `<channel>`
   tag Claude renders) and `meta` (tag attributes — keys must be
   `[A-Za-z0-9_]+`; non-string/None values are dropped per the
   channels reference).
"""

import pytest

from esr_cc_mcp import channel as channel_mod
from esr_cc_mcp.channel import _handle_inbound


class _FakeStream:
    """Captures SessionMessage objects the inbound handler tries to send."""

    def __init__(self) -> None:
        self.sent: list = []

    async def send(self, msg) -> None:
        self.sent.append(msg)


@pytest.fixture(autouse=True)
def _stub_stdio_stream(monkeypatch):
    fake = _FakeStream()
    monkeypatch.setattr(channel_mod, "_stdio_write_stream", fake)
    return fake


@pytest.mark.asyncio
async def test_notification_emits_claude_channel_method(
    _stub_stdio_stream: _FakeStream,
) -> None:
    """kind=notification → writes a SessionMessage with
    method='notifications/claude/channel'."""
    envelope = {
        "kind": "notification",
        "source": "feishu",
        "chat_id": "oc_5c21b0eec28ad69efa0a5acf47eeaf55",
        "message_id": "om_x100",
        "user": "linyilun",
        "ts": "2026-04-20T04:00:00+00:00",
        "content": "hello",
    }

    await _handle_inbound(envelope)

    assert len(_stub_stdio_stream.sent) == 1
    session_msg = _stub_stdio_stream.sent[0]
    # SessionMessage wraps a JSONRPCMessage wrapping a JSONRPCNotification.
    notification = session_msg.message.root
    assert notification.method == "notifications/claude/channel"


@pytest.mark.asyncio
async def test_notification_params_carry_content_and_meta(
    _stub_stdio_stream: _FakeStream,
) -> None:
    envelope = {
        "kind": "notification",
        "source": "feishu",
        "chat_id": "oc_abc",
        "message_id": "om_x",
        "user": "linyilun",
        "ts": "2026-04-20T04:00:00+00:00",
        "content": "hello world",
    }

    await _handle_inbound(envelope)

    params = _stub_stdio_stream.sent[0].message.root.params
    assert params["content"] == "hello world"
    meta = params["meta"]
    assert meta["chat_id"] == "oc_abc"
    assert meta["user"] == "linyilun"
    assert meta["source"] == "feishu"


@pytest.mark.asyncio
async def test_notification_drops_when_stdio_stream_unready(
    monkeypatch,
) -> None:
    """If called before stdio is established, handler logs + no-ops
    rather than crashing — covers the early-reconnect race."""
    monkeypatch.setattr(channel_mod, "_stdio_write_stream", None)

    await _handle_inbound({"kind": "notification", "content": "x"})
    # No assertion beyond "didn't raise" — the log.warning path is
    # exercised; no stream means nothing to capture.


@pytest.mark.asyncio
async def test_notification_meta_excludes_empty_values(
    _stub_stdio_stream: _FakeStream,
) -> None:
    """Meta keys with None/empty-string values must be omitted — Claude
    Code's channel listener treats missing-vs-empty differently."""
    await _handle_inbound({
        "kind": "notification",
        "chat_id": "oc_y",
        "user": "",  # empty — should be omitted
        "message_id": None,  # none — should be omitted
        "content": "test",
    })

    meta = _stub_stdio_stream.sent[0].message.root.params["meta"]
    assert "chat_id" in meta
    assert "user" not in meta
    assert "message_id" not in meta
