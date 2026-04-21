"""Capabilities spec §6.2/§6.3 — msg_received envelope carries
``principal_id`` and ``workspace_name``.

The Feishu adapter loads ``workspaces.yaml`` at startup into a
``(chat_id, app_id) → workspace_name`` reverse-lookup map. Every
``msg_received`` envelope (produced by the three inbound paths —
live WS, polling fallback, mock) gains:

- ``principal_id``: the sender's ``open_id`` (authoritative identity
  token for Lane A + Lane B permission checks).
- ``workspace_name``: the workspace the (chat_id, app_id) tuple is
  bound to, or ``None`` if the chat is unbound (Lane A denies unless
  the principal is the bootstrap admin).
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

from esr.adapter import AdapterConfig
from esr.workspaces import Workspace, write_workspace
from esr_feishu.adapter import FeishuAdapter


@pytest.fixture
def workspaces_file(tmp_path: Path) -> Path:
    """Create a workspaces.yaml binding chat ``oc_bound`` to ``proj-a``."""
    path = tmp_path / "workspaces.yaml"
    write_workspace(
        path,
        Workspace(
            name="proj-a",
            cwd="/tmp/proj-a",
            start_cmd="esr-cc",
            role="dev",
            chats=[
                {
                    "chat_id": "oc_bound",
                    "app_id": "cli_test_app",
                    "kind": "dm",
                }
            ],
            env={},
        ),
    )
    return path


@pytest.fixture
def adapter_with_ws(workspaces_file: Path) -> FeishuAdapter:
    """Adapter instance that loads the fixture workspaces.yaml at init."""
    cfg = AdapterConfig(
        {
            "app_id": "cli_test_app",
            "app_secret": "s",
            "workspaces_path": str(workspaces_file),
        }
    )
    return FeishuAdapter(actor_id="feishu-app:test", config=cfg)


def test_envelope_principal_id_is_sender_open_id(
    adapter_with_ws: FeishuAdapter,
) -> None:
    env = adapter_with_ws._build_msg_received_envelope(
        args={"chat_id": "oc_bound", "sender_id": "ou_alice"},
        sender_open_id="ou_alice",
    )
    assert env["event_type"] == "msg_received"
    assert env["principal_id"] == "ou_alice"


def test_envelope_workspace_name_resolved_from_lookup(
    adapter_with_ws: FeishuAdapter,
) -> None:
    env = adapter_with_ws._build_msg_received_envelope(
        args={"chat_id": "oc_bound", "sender_id": "ou_alice"},
        sender_open_id="ou_alice",
    )
    assert env["workspace_name"] == "proj-a"


def test_envelope_workspace_nil_when_chat_unbound(
    adapter_with_ws: FeishuAdapter,
) -> None:
    """Chats not listed in any workspace → ``workspace_name=None``."""
    env = adapter_with_ws._build_msg_received_envelope(
        args={"chat_id": "oc_unbound", "sender_id": "ou_alice"},
        sender_open_id="ou_alice",
    )
    assert env["workspace_name"] is None


def test_envelope_workspace_nil_when_no_workspaces_yaml(
    tmp_path: Path,
) -> None:
    """Missing workspaces.yaml → empty lookup map → all
    envelopes carry ``workspace_name=None``. No crash."""
    missing = tmp_path / "nope.yaml"
    cfg = AdapterConfig(
        {
            "app_id": "cli_test_app",
            "app_secret": "s",
            "workspaces_path": str(missing),
        }
    )
    adapter = FeishuAdapter(actor_id="feishu-app:test", config=cfg)
    env = adapter._build_msg_received_envelope(
        args={"chat_id": "oc_anything", "sender_id": "ou_x"},
        sender_open_id="ou_x",
    )
    assert env["workspace_name"] is None


def test_envelope_app_id_discriminates_lookup(tmp_path: Path) -> None:
    """Same chat_id under a different app_id must NOT match.

    workspaces.yaml ties (chat_id, app_id); a chat registered under
    ``cli_A`` must not leak to an adapter bound to ``cli_B``.
    """
    path = tmp_path / "workspaces.yaml"
    write_workspace(
        path,
        Workspace(
            name="proj-x",
            cwd="/tmp",
            start_cmd="x",
            role="dev",
            chats=[
                {"chat_id": "oc_shared", "app_id": "cli_A", "kind": "dm"},
            ],
        ),
    )
    # Adapter running under a DIFFERENT app_id
    cfg = AdapterConfig(
        {
            "app_id": "cli_B",
            "app_secret": "s",
            "workspaces_path": str(path),
        }
    )
    adapter = FeishuAdapter(actor_id="feishu-app:test", config=cfg)
    env = adapter._build_msg_received_envelope(
        args={"chat_id": "oc_shared", "sender_id": "ou_y"},
        sender_open_id="ou_y",
    )
    assert env["workspace_name"] is None  # not cli_B's workspace


# --- mock path end-to-end: adapter emit_events yields the new fields ---


@pytest.mark.asyncio
async def test_mock_path_envelope_has_principal_and_workspace(
    workspaces_file: Path,
    allow_all_capabilities: Path,
) -> None:
    """Drive the mock path end-to-end and assert the yielded envelope
    carries both capability fields. This pins the three-site helper
    integration, not just the unit test of the helper."""
    import asyncio

    _SCRIPTS = Path(__file__).resolve().parents[3] / "scripts"
    sys.path.insert(0, str(_SCRIPTS))
    from mock_feishu import MockFeishu  # noqa: E402 — scripts import

    mock = MockFeishu()
    url = await mock.start()
    try:
        adapter = FeishuAdapter(
            actor_id="feishu-app:test",
            config=AdapterConfig(
                {
                    "app_id": "cli_test_app",
                    "app_secret": "s",
                    "base_url": url,
                    "workspaces_path": str(workspaces_file),
                    "capabilities_path": str(allow_all_capabilities),
                }
            ),
        )

        gen = adapter.emit_events()

        async def _seed_soon() -> None:
            await asyncio.sleep(0.2)
            mock.push_inbound(
                chat_id="oc_bound",
                sender_open_id="ou_alice",
                content_text="hi",
            )

        seed = asyncio.create_task(_seed_soon())
        try:
            envelope = await asyncio.wait_for(gen.__anext__(), timeout=5.0)
        finally:
            seed.cancel()
            await gen.aclose()

        assert envelope["event_type"] == "msg_received"
        assert envelope["principal_id"] == "ou_alice"
        assert envelope["workspace_name"] == "proj-a"
    finally:
        await mock.stop()
