from esr_cc_mcp.tools import list_tool_schemas


def test_returns_3_tools_by_default() -> None:
    tools = list_tool_schemas(role="dev")
    names = {t.name for t in tools}
    assert names == {"reply", "react", "send_file"}


def test_diagnostic_role_adds_echo_tool() -> None:
    tools = list_tool_schemas(role="diagnostic")
    names = {t.name for t in tools}
    assert names == {"reply", "react", "send_file", "_echo"}


def test_reply_schema_has_chat_id_and_text() -> None:
    tools = list_tool_schemas(role="dev")
    reply = next(t for t in tools if t.name == "reply")
    props = reply.inputSchema["properties"]
    assert "chat_id" in props
    assert "text" in props
    assert props["chat_id"]["type"] == "string"
