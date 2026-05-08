"""PRD 04 F14 — feishu file download directive.

Per spec docs/superpowers/specs/2026-05-08-multimedia-content-protocol-design.md
PR-2 §4.2 row B: _download_file now content-addresses bytes via
esr.resource.media.store and returns {ok, result: {uri, sha256, path}}.
"""

from __future__ import annotations

import hashlib
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


async def test_download_file_returns_uri_sha256_path(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """download_file returns {ok, result: {uri, sha256, path}} with content-addressed storage."""
    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    monkeypatch.setenv("ESR_INSTANCE", "test")

    from esr_feishu.adapter import FeishuAdapter

    fake_bytes = b"\x89PNG\r\n\x1a\nfake-image-data"
    expected_sha = hashlib.sha256(fake_bytes).hexdigest()

    instance = FeishuAdapter.factory(
        "feishu-shared",
        AdapterConfig({"app_id": "a", "app_secret": "b"}),
    )
    stub = _make_stub(_StubBinaryResponse(fake_bytes))
    instance._lark_client = stub

    result = await instance.on_directive(
        "download_file",
        {
            "msg_id": "om_xx",
            "file_key": "img_yyy",
            "file_name": "screenshot.png",
            "msg_type": "image",
            "chat_id": "oc_test",
        },
    )

    assert result["ok"] is True
    r = result["result"]
    assert "uri" in r
    assert "sha256" in r
    assert "path" in r
    assert r["sha256"] == expected_sha
    assert f"resources/image/{expected_sha}.png" in r["uri"]
    assert Path(r["path"]).exists()
    assert Path(r["path"]).read_bytes() == fake_bytes


async def test_download_file_path_is_content_addressed(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """Path is resources/<media_type>/<sha256>.<ext>, not uploads/<chat_id>/<file_name>."""
    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    monkeypatch.setenv("ESR_INSTANCE", "test")

    from esr_feishu.adapter import FeishuAdapter

    fake_bytes = b"hello-bytes"
    expected_sha = hashlib.sha256(fake_bytes).hexdigest()

    instance = FeishuAdapter.factory(
        "feishu-shared",
        AdapterConfig({"app_id": "a", "app_secret": "b"}),
    )
    stub = _make_stub(_StubBinaryResponse(fake_bytes))
    instance._lark_client = stub

    result = await instance.on_directive(
        "download_file",
        {
            "msg_id": "om_abc",
            "file_key": "file_xyz",
            "file_name": "doc.pdf",
            "msg_type": "file",
            "chat_id": "oc_chat",
        },
    )

    assert result["ok"] is True
    stored = Path(result["result"]["path"])
    assert stored.exists()
    assert stored.read_bytes() == fake_bytes
    # Content-addressed layout: resources/<media_type>/<sha256>.<ext>
    assert stored.name == f"{expected_sha}.pdf"
    assert stored.parent.name == "file"
    # NOT chat-keyed uploads layout
    assert "uploads" not in str(stored)
    assert "oc_chat" not in str(stored)


async def test_download_file_sets_request_fields(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """The GetMessageResourceRequest receives msg_id + file_key + type."""
    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    monkeypatch.setenv("ESR_INSTANCE", "test")

    from esr_feishu.adapter import FeishuAdapter

    instance = FeishuAdapter.factory(
        "feishu-shared",
        AdapterConfig({"app_id": "a", "app_secret": "b"}),
    )
    stub = _make_stub(_StubBinaryResponse(b"\x89PNG\r\n\x1a\nx"))
    instance._lark_client = stub

    await instance.on_directive(
        "download_file",
        {
            "msg_id": "om_1",
            "file_key": "key_1",
            "file_name": "a.png",
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
    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    monkeypatch.setenv("ESR_INSTANCE", "test")

    from esr_feishu.adapter import FeishuAdapter

    instance = FeishuAdapter.factory(
        "feishu-shared",
        AdapterConfig({"app_id": "a", "app_secret": "b"}),
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
