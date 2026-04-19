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


# --- F07: send_message -------------------------------------------------


class _StubReceiveIdType:
    CHAT_ID = "chat_id"


class _StubMsgType:
    TEXT = "text"


class _StubResponse:
    """Emulates lark_oapi response objects: .success() / .data.message_id."""

    def __init__(self, success: bool, message_id: str = "", error: str = "") -> None:
        self._success = success
        self._error = error
        self.data = type("D", (), {"message_id": message_id})()

    def success(self) -> bool:
        return self._success


class _StubMessageApi:
    def __init__(self) -> None:
        self.last_request: object | None = None
        self.canned_response: _StubResponse = _StubResponse(True, "msg_42")

    def create(self, request: object) -> _StubResponse:
        self.last_request = request
        return self.canned_response


class _StubClient:
    def __init__(self) -> None:
        self.im = type("IM", (), {"v1": type("V1", (), {"message": _StubMessageApi()})()})()


async def test_send_message_calls_lark_im_v1_create() -> None:
    """send_message invokes client.im.v1.message.create with the expected request."""
    instance = _make_adapter()
    stub_client = _StubClient()
    # Replace the cached client so on_directive uses the stub
    instance._lark_client = stub_client

    ack = await instance.on_directive(
        "send_message", {"chat_id": "oc_abc", "content": "hello"}
    )
    assert ack == {"ok": True, "result": {"message_id": "msg_42"}}

    req = stub_client.im.v1.message.last_request
    assert req is not None
    # Expect the SDK builder shape: request.request_body has receive_id,
    # msg_type ("text"), and a JSON-serialised content field.
    body = req.request_body  # CreateMessageRequestBody
    assert body.receive_id == "oc_abc"
    assert body.msg_type == "text"
    assert "hello" in body.content  # content is JSON like {"text": "hello"}


async def test_send_message_surfaces_lark_error() -> None:
    """A lark failure (success()==False) becomes {ok: False, error: ...}."""
    instance = _make_adapter()
    stub_client = _StubClient()
    stub_client.im.v1.message.canned_response = _StubResponse(
        False, error="rate limited"
    )
    instance._lark_client = stub_client

    ack = await instance.on_directive(
        "send_message", {"chat_id": "oc_abc", "content": "hi"}
    )
    assert ack["ok"] is False
