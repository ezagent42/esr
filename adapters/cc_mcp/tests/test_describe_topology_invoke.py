"""PR-F 2026-04-28: cc_mcp's describe_topology MCP tool.

The LLM-facing API is parameter-less; cc_mcp injects `workspace_name`
from the `ESR_WORKSPACE` env var into the `tool_invoke` envelope's
args before pushing to esrd. These tests verify the injection without
standing up a real esrd or stdio bridge.
"""

import json

import pytest

from esr_cc_mcp import channel as channel_mod
from esr_cc_mcp.channel import _invoke_tool


class _FakeWS:
    """Captures push payloads + can fake a tool_result reply."""

    def __init__(self, fake_result: dict | None = None) -> None:
        self.pushed: list[dict] = []
        self._fake_result = fake_result or {"ok": True, "data": {"current_workspace": {}}}

    async def push(self, payload: dict) -> None:
        self.pushed.append(payload)
        # Resolve the awaiting future so _invoke_tool returns.
        req_id = payload.get("req_id")
        if req_id:
            fut = channel_mod._pending.pop(req_id, None)
            if fut is not None and not fut.done():
                fut.set_result(self._fake_result)


@pytest.fixture
def fake_ws(monkeypatch):
    fake = _FakeWS()
    monkeypatch.setattr(channel_mod, "_ws", fake)
    return fake


@pytest.mark.asyncio
async def test_describe_topology_injects_workspace_name(fake_ws, monkeypatch) -> None:
    """When ESR_WORKSPACE is set, _invoke_tool injects workspace_name
    into the tool_invoke args even though the LLM passes empty args."""
    monkeypatch.setenv("ESR_WORKSPACE", "ws_translator")

    result = await _invoke_tool("describe_topology", {})
    assert isinstance(result, list) and len(result) == 1

    assert len(fake_ws.pushed) == 1
    pushed = fake_ws.pushed[0]
    assert pushed["kind"] == "tool_invoke"
    assert pushed["tool"] == "describe_topology"
    assert pushed["args"]["workspace_name"] == "ws_translator"


@pytest.mark.asyncio
async def test_describe_topology_passes_through_when_env_unset(fake_ws, monkeypatch) -> None:
    """No ESR_WORKSPACE → no injection; runtime returns
    `unknown_workspace` error which the LLM sees verbatim. Defensive
    behaviour: don't fabricate a workspace name."""
    monkeypatch.delenv("ESR_WORKSPACE", raising=False)

    await _invoke_tool("describe_topology", {})

    pushed = fake_ws.pushed[0]
    assert "workspace_name" not in pushed["args"]


@pytest.mark.asyncio
async def test_other_tools_do_not_get_workspace_injected(fake_ws, monkeypatch) -> None:
    """The injection is describe_topology-specific. reply / send_file
    must NOT pick up workspace_name (they take chat_id / app_id from
    the LLM's args)."""
    monkeypatch.setenv("ESR_WORKSPACE", "ws_x")

    await _invoke_tool("reply", {"chat_id": "oc_x", "app_id": "cli_x", "text": "hi"})

    pushed = fake_ws.pushed[0]
    assert pushed["tool"] == "reply"
    assert "workspace_name" not in pushed["args"]


@pytest.mark.asyncio
async def test_describe_topology_preserves_explicit_args(fake_ws, monkeypatch) -> None:
    """If the LLM somehow passes args (future-proofing), they're
    merged with workspace_name — the env-injected value doesn't
    overwrite explicit ones. (Currently the schema rejects any args,
    but the runtime invariant is still worth pinning.)"""
    monkeypatch.setenv("ESR_WORKSPACE", "ws_default")

    await _invoke_tool("describe_topology", {"some_future_arg": "value"})

    pushed = fake_ws.pushed[0]
    assert pushed["args"]["some_future_arg"] == "value"
    assert pushed["args"]["workspace_name"] == "ws_default"


@pytest.mark.asyncio
async def test_describe_topology_returns_runtime_data_unwrapped() -> None:
    """The runtime returns `{"ok": True, "data": {...}}` per spec §4.2;
    the tool handler currently passes that through verbatim as JSON
    string (no extra unwrapping). The LLM reads `data.current_workspace`
    etc. from the parsed JSON — verify the JSON is valid."""

    class _ResultStubWS:
        def __init__(self) -> None:
            self.pushed: list[dict] = []

        async def push(self, payload: dict) -> None:
            self.pushed.append(payload)
            req_id = payload.get("req_id")
            fake_runtime_result = {
                "ok": True,
                "data": {
                    "current_workspace": {
                        "name": "ws_x",
                        "metadata": {"purpose": "test"},
                    },
                    "neighbor_workspaces": [],
                },
            }
            fut = channel_mod._pending.pop(req_id, None)
            if fut is not None and not fut.done():
                fut.set_result(fake_runtime_result)

    stub = _ResultStubWS()
    saved_ws = channel_mod._ws
    channel_mod._ws = stub  # type: ignore[assignment]
    try:
        result = await _invoke_tool("describe_topology", {})
    finally:
        channel_mod._ws = saved_ws  # type: ignore[assignment]

    assert len(result) == 1
    parsed = json.loads(result[0].text)
    assert parsed["ok"] is True
    assert parsed["data"]["current_workspace"]["name"] == "ws_x"
    assert parsed["data"]["current_workspace"]["metadata"]["purpose"] == "test"
