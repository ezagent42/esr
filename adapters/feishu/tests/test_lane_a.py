"""Lane A (adapter-side) capability enforcement — spec §7.1.

The adapter must:

1. Drop any ``msg_received`` whose sender lacks
   ``workspace:<name>/msg.send`` for the chat's bound workspace.
2. Send the denied principal one rate-limited DM per 10 min explaining
   why nothing happened; further denials within the window are silent.
3. Let authorized principals through unchanged.

These tests exercise the mock path (``base_url=http://127.0.0.1:<port>``)
end-to-end: MockFeishu pushes a P2ImMessageReceiveV1 frame; the adapter
gates it through ``CapabilitiesChecker`` loaded from a tmp-file
``capabilities.yaml``.
"""
from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path
from typing import Any

import pytest
import yaml
from esr_feishu.adapter import FeishuAdapter

from esr.adapter import AdapterConfig
from esr.workspaces import Workspace, write_workspace

_SCRIPTS = Path(__file__).resolve().parents[3] / "scripts"
sys.path.insert(0, str(_SCRIPTS))
from mock_feishu import MockFeishu  # noqa: E402 — scripts/ import

_APP_ID = "cli_lane_a"
_CHAT_BOUND = "oc_proj_a"


def _deny_dm_messages(sent: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Filter ``sent_messages`` down to the Lane A deny DMs.

    MockFeishu stores the outbound content JSON-encoded (the Lark wire
    format is ``{"text": "..."}`` as a string). We decode each message's
    content and match on the plain-text deny string — this sidesteps the
    ``ensure_ascii`` default that would otherwise embed the Chinese
    warning as ``\\u…`` escapes.
    """
    out: list[dict[str, Any]] = []
    for m in sent:
        content = m.get("content") or ""
        try:
            inner = json.loads(content)
        except (ValueError, TypeError):
            continue
        text = inner.get("text", "") if isinstance(inner, dict) else ""
        if "无权使用" in text:
            out.append(m)
    return out


def _write_workspaces(path: Path) -> None:
    write_workspace(
        path,
        Workspace(
            name="proj-a",
            cwd="/tmp/proj-a",
            start_cmd="esr-cc",
            role="dev",
            chats=[{"chat_id": _CHAT_BOUND, "app_id": _APP_ID, "kind": "dm"}],
        ),
    )


def _write_caps(path: Path, principals: list[dict]) -> None:
    path.write_text(yaml.safe_dump({"principals": principals}, sort_keys=False))


def _make_adapter(
    tmp_path: Path,
    base_url: str,
    caps: list[dict],
) -> FeishuAdapter:
    ws_path = tmp_path / "workspaces.yaml"
    cap_path = tmp_path / "capabilities.yaml"
    _write_workspaces(ws_path)
    _write_caps(cap_path, caps)
    return FeishuAdapter(
        actor_id="feishu-app:test",
        config=AdapterConfig(
            {
                "app_id": _APP_ID,
                "app_secret": "s",
                "base_url": base_url,
                "workspaces_path": str(ws_path),
                "capabilities_path": str(cap_path),
            }
        ),
    )


async def _next_or_timeout(gen, timeout: float):
    """Drive the generator one step, returning None on timeout."""
    try:
        return await asyncio.wait_for(gen.__anext__(), timeout=timeout)
    except TimeoutError:
        return None


# --- authorized path ------------------------------------------------


@pytest.mark.asyncio
async def test_authorized_user_event_is_emitted(tmp_path: Path) -> None:
    """``ou_alice`` holds ``workspace:proj-a/msg.send`` → event flows
    through, no deny DM is sent."""
    mock = MockFeishu()
    url = await mock.start()
    try:
        adapter = _make_adapter(
            tmp_path,
            url,
            caps=[
                {
                    "id": "ou_alice",
                    "kind": "feishu_user",
                    "capabilities": ["workspace:proj-a/msg.send"],
                }
            ],
        )
        gen = adapter.emit_events()

        async def _seed() -> None:
            await asyncio.sleep(0.2)
            mock.push_inbound(
                chat_id=_CHAT_BOUND,
                sender_open_id="ou_alice",
                content_text="hello",
            )

        seed = asyncio.create_task(_seed())
        try:
            envelope = await _next_or_timeout(gen, timeout=5.0)
        finally:
            seed.cancel()
            await gen.aclose()

        assert envelope is not None
        assert envelope["event_type"] == "msg_received"
        assert envelope["principal_id"] == "ou_alice"
        assert envelope["workspace_name"] == "proj-a"
        # No deny DM posted
        assert mock.sent_messages == []
    finally:
        await mock.stop()


# --- deny path + rate-limit -----------------------------------------


@pytest.mark.asyncio
async def test_unauthorized_user_is_denied_and_rate_limited(
    tmp_path: Path,
) -> None:
    """``ou_rando`` holds nothing → event is dropped, one deny DM is
    sent, a second inbound within 10 min emits no further DM."""
    mock = MockFeishu()
    url = await mock.start()
    try:
        adapter = _make_adapter(tmp_path, url, caps=[])  # no principals
        gen = adapter.emit_events()

        async def _seed_two() -> None:
            # Give the WS time to connect
            await asyncio.sleep(0.2)
            mock.push_inbound(
                chat_id=_CHAT_BOUND,
                sender_open_id="ou_rando",
                content_text="first",
            )
            # Give the adapter time to process + send the deny DM
            await asyncio.sleep(0.3)
            mock.push_inbound(
                chat_id=_CHAT_BOUND,
                sender_open_id="ou_rando",
                content_text="second",
            )

        seed = asyncio.create_task(_seed_two())
        try:
            # Expect no event to come through — drive the generator for
            # up to 1s and verify timeout.
            envelope = await _next_or_timeout(gen, timeout=1.5)
        finally:
            seed.cancel()
            await gen.aclose()

        assert envelope is None  # nothing emitted

        # Exactly one deny DM — rate-limited second attempt is silent.
        # The deny flies out via the mock's /open-apis/im/v1/messages
        # endpoint (same path _send_message uses).
        deny_msgs = _deny_dm_messages(mock.sent_messages)
        assert len(deny_msgs) == 1
        assert deny_msgs[0]["receive_id"] == _CHAT_BOUND
    finally:
        await mock.stop()


@pytest.mark.asyncio
async def test_deny_rate_limit_expires_after_window(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Monkeypatch ``time.monotonic`` to advance past the 600s window;
    a second deny DM must fire. Guards the plan's S6 fix — without the
    ``self._last_deny_ts[open_id] = now`` update happening AFTER the
    window-gate, the rate-limit wouldn't reset."""
    # We test the rate-limit gate directly against the adapter's
    # `_deny_rate_limited` helper — the mock-path end-to-end timing is
    # too coarse to pin a 600s boundary without stalling CI.
    mock = MockFeishu()
    url = await mock.start()
    try:
        adapter = _make_adapter(tmp_path, url, caps=[])

        clock = [1000.0]
        monkeypatch.setattr(
            "esr_feishu.adapter.time.monotonic", lambda: clock[0]
        )

        # t=1000: first deny fires
        await adapter._deny_rate_limited("ou_rando", _CHAT_BOUND)
        assert len(_deny_dm_messages(mock.sent_messages)) == 1

        # t=1500: still within window, no new DM
        clock[0] = 1500.0
        await adapter._deny_rate_limited("ou_rando", _CHAT_BOUND)
        assert len(_deny_dm_messages(mock.sent_messages)) == 1

        # t=1601: 601s after first — outside window, DM must fire again.
        clock[0] = 1601.0
        await adapter._deny_rate_limited("ou_rando", _CHAT_BOUND)
        assert len(_deny_dm_messages(mock.sent_messages)) == 2
    finally:
        await mock.stop()


# --- unit-level gating ---------------------------------------------


def test_is_authorized_denies_unbound_chat(tmp_path: Path) -> None:
    """Even admin ``*`` can't pass if the chat isn't in workspaces.yaml.

    ``_is_authorized`` returns False when the (chat_id, app_id) lookup
    yields no workspace — Lane A can't construct a meaningful
    ``workspace:<name>/msg.send`` without a name.
    """
    ws_path = tmp_path / "workspaces.yaml"
    cap_path = tmp_path / "capabilities.yaml"
    _write_workspaces(ws_path)
    _write_caps(
        cap_path, [{"id": "ou_admin", "capabilities": ["*"]}]
    )
    adapter = FeishuAdapter(
        actor_id="feishu-app:test",
        config=AdapterConfig(
            {
                "app_id": _APP_ID,
                "app_secret": "s",
                "workspaces_path": str(ws_path),
                "capabilities_path": str(cap_path),
            }
        ),
    )
    # Bound chat + admin → allowed
    assert adapter._is_authorized("ou_admin", _CHAT_BOUND) is True
    # Unbound chat + admin → denied (no workspace to scope against)
    assert adapter._is_authorized("ou_admin", "oc_nowhere") is False


def test_is_authorized_denies_empty_open_id(tmp_path: Path) -> None:
    ws_path = tmp_path / "workspaces.yaml"
    cap_path = tmp_path / "capabilities.yaml"
    _write_workspaces(ws_path)
    _write_caps(
        cap_path, [{"id": "ou_admin", "capabilities": ["*"]}]
    )
    adapter = FeishuAdapter(
        actor_id="feishu-app:test",
        config=AdapterConfig(
            {
                "app_id": _APP_ID,
                "app_secret": "s",
                "workspaces_path": str(ws_path),
                "capabilities_path": str(cap_path),
            }
        ),
    )
    assert adapter._is_authorized("", _CHAT_BOUND) is False


def test_capabilities_file_reload_is_picked_up(
    tmp_path: Path,
) -> None:
    """Admin edits capabilities.yaml at runtime → CapabilitiesChecker's
    mtime-gated reload picks up the new grant on the next ``has()``.

    Lane A has no fs_watch — this test is the contract that an admin
    running ``esr cap grant`` is visible within one inbound message.
    """
    import os as _os

    ws_path = tmp_path / "workspaces.yaml"
    cap_path = tmp_path / "capabilities.yaml"
    _write_workspaces(ws_path)
    _write_caps(cap_path, [])
    adapter = FeishuAdapter(
        actor_id="feishu-app:test",
        config=AdapterConfig(
            {
                "app_id": _APP_ID,
                "app_secret": "s",
                "workspaces_path": str(ws_path),
                "capabilities_path": str(cap_path),
            }
        ),
    )
    assert adapter._is_authorized("ou_new", _CHAT_BOUND) is False

    # Admin edits caps.yaml, bumps mtime
    _write_caps(
        cap_path,
        [
            {
                "id": "ou_new",
                "capabilities": ["workspace:proj-a/msg.send"],
            }
        ],
    )
    _os.utime(
        cap_path,
        (cap_path.stat().st_atime, cap_path.stat().st_mtime + 1.0),
    )
    assert adapter._is_authorized("ou_new", _CHAT_BOUND) is True
