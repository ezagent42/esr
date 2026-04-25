from esr_cc_mcp.tools import list_tool_schemas


def test_returns_2_tools_by_default() -> None:
    # PR-9 T5 D4: `react` removed — no longer a CC-facing MCP tool;
    # it's emitted by FeishuChatProxy as a delivery ACK and un-reacted
    # on CC reply, keeping Feishu-specific semantics out of CC.
    tools = list_tool_schemas(role="dev")
    names = {t.name for t in tools}
    assert names == {"reply", "send_file"}


def test_diagnostic_role_adds_echo_tool() -> None:
    tools = list_tool_schemas(role="diagnostic")
    names = {t.name for t in tools}
    assert names == {"reply", "send_file", "_echo"}


def test_reply_schema_has_chat_id_and_text() -> None:
    tools = list_tool_schemas(role="dev")
    reply = next(t for t in tools if t.name == "reply")
    props = reply.inputSchema["properties"]
    assert "chat_id" in props
    assert "text" in props
    assert props["chat_id"]["type"] == "string"


def test_reply_schema_carries_optional_reply_to_message_id() -> None:
    """PR-9 T5c: optional field; production callers SHOULD include it."""
    tools = list_tool_schemas(role="dev")
    reply = next(t for t in tools if t.name == "reply")
    props = reply.inputSchema["properties"]
    assert "reply_to_message_id" in props
    assert props["reply_to_message_id"]["type"] == "string"
    # NOT in required — backward compat for legacy callers.
    assert "reply_to_message_id" not in reply.inputSchema["required"]


def test_reply_schema_requires_app_id():
    """T-PR-A: reply tool must require app_id explicitly (no default)."""
    from esr_cc_mcp.tools import list_tool_schemas

    tools = list_tool_schemas(role="dev")
    reply = next(t for t in tools if t.name == "reply")

    schema = reply.inputSchema
    assert "app_id" in schema["properties"], "reply schema missing app_id property"
    assert "app_id" in schema["required"], (
        "app_id must be REQUIRED on reply per PR-A spec §2.4 — explicit, no default"
    )
    # Description should tell claude where to source the value
    assert "channel" in schema["properties"]["app_id"]["description"].lower() \
        or "instance" in schema["properties"]["app_id"]["description"].lower()
