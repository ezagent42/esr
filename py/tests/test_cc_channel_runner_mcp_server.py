"""Unit tests for cc_channel_runner.mcp_server (Task 2.3 scaffold)."""

import pytest

from cc_channel_runner.mcp_server import BridgeMCPServer


@pytest.mark.asyncio
async def test_list_tools_returns_three_tools():
    """Server exposes reply / send_file / submit_slash."""
    server = BridgeMCPServer()

    # The Server SDK stores registered handlers on
    # `request_handlers[ListToolsRequest]`. Invoke it through the
    # underlying Server's registered handler dict.
    from mcp.types import ListToolsRequest

    handler = server._server.request_handlers[ListToolsRequest]
    # Build a minimal request — list_tools takes no params.
    req = ListToolsRequest(method="tools/list", params=None)
    result = await handler(req)

    tool_names = sorted(t.name for t in result.root.tools)
    assert tool_names == ["reply", "send_file", "submit_slash"]


@pytest.mark.asyncio
async def test_call_tool_without_phx_client_returns_error():
    """Tool handlers fail closed when phx_client isn't configured.

    Task 2.3 only wired stubs (`not_implemented`); Task 2.5 replaced
    them with real dispatch that requires a phx_client. With no
    phx_client set the dispatch path returns `phx_client_not_configured`
    — this guards the "scaffold without state" boundary.
    """
    server = BridgeMCPServer()

    from mcp.types import CallToolRequest, CallToolRequestParams

    handler = server._server.request_handlers[CallToolRequest]
    req = CallToolRequest(
        method="tools/call",
        params=CallToolRequestParams(name="reply", arguments={"chat_id": "oc_x", "text": "hi"}),
    )
    result = await handler(req)
    content = result.root.content
    assert len(content) == 1
    assert "phx_client_not_configured" in content[0].text


def test_unknown_tool_returns_error_payload():
    """call_tool with an unknown name doesn't raise; returns error text."""
    server = BridgeMCPServer()

    import asyncio

    from mcp.types import CallToolRequest, CallToolRequestParams

    handler = server._server.request_handlers[CallToolRequest]
    req = CallToolRequest(
        method="tools/call",
        params=CallToolRequestParams(name="bogus", arguments={}),
    )
    result = asyncio.run(handler(req))
    content = result.root.content
    assert "unknown_tool: bogus" in content[0].text


def test_set_phx_client_and_session_id():
    """Configuration setters store state for later dispatch."""
    server = BridgeMCPServer()

    class StubClient:
        pass

    stub = StubClient()
    server.set_phx_client(stub)
    server.set_session_id("test-sid-123")

    assert server._phx_client is stub
    assert server._session_id == "test-sid-123"
    assert server._topic == "cli:channel/test-sid-123"
