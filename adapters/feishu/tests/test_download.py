"""PRD 04 F14 — feishu file download directive."""

from __future__ import annotations

from pathlib import Path

import pytest

from esr.adapter import AdapterConfig


class _StubBinaryResponse:
    def __init__(self, raw_bytes: bytes) -> None:
        self.file = type("F", (), {"read": lambda self: raw_bytes})()
        self.code = 0

    def success(self) -> bool:
        return True


class _StubFailedResponse:
    def __init__(self) -> None:
        self.code = 404
        self.msg = "not found"

    def success(self) -> bool:
        return False


class _StubResourceApi:
    def __init__(self, response: object) -> None:
        self.last_request: object | None = None
        self._response = response

    def get(self, request: object) -> object:
        self.last_request = request
        return self._response


class _StubMessageAttr:
    def __init__(self, resource_response: object) -> None:
        self.resource = _StubResourceApi(resource_response)


def _make_stub(resource_response: object) -> object:
    stub = type(
        "C",
        (),
        {
            "im": type(
                "IM",
                (),
                {"v1": type("V1", (), {"message_resource": _StubResourceApi(resource_response)})()},
            )()
        },
    )()
    return stub


async def test_download_file_writes_to_uploads_dir(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """download_file saves to <uploads_dir>/<chat_id>/<file_name>."""
    from esr_feishu.adapter import FeishuAdapter

    instance = FeishuAdapter.factory(
        "feishu-shared",
        AdapterConfig(
            {"app_id": "a", "app_secret": "b", "uploads_dir": str(tmp_path / "uploads")}
        ),
    )
    stub = _make_stub(_StubBinaryResponse(b"hello-bytes"))
    instance._lark_client = stub

    ack = await instance.on_directive(
        "download_file",
        {
            "msg_id": "om_abc",
            "file_key": "file_xyz",
            "file_name": "doc.pdf",
            "msg_type": "file",
            "chat_id": "oc_chat",
        },
    )
    assert ack["ok"] is True
    saved = Path(ack["result"]["path"])
    assert saved.exists()
    assert saved.read_bytes() == b"hello-bytes"
    # Layout: <uploads_dir>/<chat_id>/<file_name>
    assert saved.parent.name == "oc_chat"
    assert saved.name == "doc.pdf"


async def test_download_file_sets_request_fields(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """The GetMessageResourceRequest receives msg_id + file_key + type."""
    from esr_feishu.adapter import FeishuAdapter

    instance = FeishuAdapter.factory(
        "feishu-shared",
        AdapterConfig({"app_id": "a", "app_secret": "b", "uploads_dir": str(tmp_path)}),
    )
    stub = _make_stub(_StubBinaryResponse(b"x"))
    instance._lark_client = stub

    await instance.on_directive(
        "download_file",
        {
            "msg_id": "om_1",
            "file_key": "key_1",
            "file_name": "a.bin",
            "msg_type": "image",
            "chat_id": "oc_1",
        },
    )

    req = stub.im.v1.message_resource.last_request
    assert req is not None
    assert req.message_id == "om_1"
    assert req.file_key == "key_1"
    assert req.type == "image"


async def test_download_file_surfaces_lark_error(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    from esr_feishu.adapter import FeishuAdapter

    instance = FeishuAdapter.factory(
        "feishu-shared",
        AdapterConfig({"app_id": "a", "app_secret": "b", "uploads_dir": str(tmp_path)}),
    )
    stub = _make_stub(_StubFailedResponse())
    instance._lark_client = stub

    ack = await instance.on_directive(
        "download_file",
        {
            "msg_id": "om_1",
            "file_key": "key_1",
            "file_name": "a.bin",
            "msg_type": "file",
            "chat_id": "oc_1",
        },
    )
    assert ack["ok"] is False
