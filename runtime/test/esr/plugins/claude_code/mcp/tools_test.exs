defmodule Esr.Plugins.ClaudeCode.Mcp.ToolsTest do
  @moduledoc """
  Phase 7 (2026-05-10): every session-scoped tool's inputSchema must
  carry an optional `current_session_id` property so the runtime can
  route a multi-session-per-instance reply back to the right session's
  cli:channel + chat_proxy.
  """

  use ExUnit.Case, async: true

  alias Esr.Plugins.ClaudeCode.Mcp.Tools

  describe "list/1 — Phase 7 current_session_id property" do
    test "reply tool advertises current_session_id" do
      tools = Tools.list("dev")
      reply = Enum.find(tools, &(&1["name"] == "reply"))

      assert is_map(reply), "reply tool must be present in the catalog"

      props = get_in(reply, ["inputSchema", "properties"])
      assert is_map(props["current_session_id"]),
             "reply tool inputSchema must declare current_session_id (Phase 7)"

      # Optional — not in `required`.
      required = get_in(reply, ["inputSchema", "required"])
      refute "current_session_id" in required,
             "current_session_id is optional; required list must NOT include it"
    end

    test "send_file tool advertises current_session_id" do
      tools = Tools.list("dev")
      send_file = Enum.find(tools, &(&1["name"] == "send_file"))

      assert is_map(send_file)

      props = get_in(send_file, ["inputSchema", "properties"])
      assert is_map(props["current_session_id"]),
             "send_file tool inputSchema must declare current_session_id (Phase 7)"
    end

    test "diagnostic role still gets _echo (regression pin for the role gate)" do
      tools = Tools.list("diagnostic")
      names = Enum.map(tools, & &1["name"])
      assert "_echo" in names
      assert "reply" in names
      assert "send_file" in names
    end

    test "non-diagnostic role does NOT get _echo" do
      tools = Tools.list("dev")
      names = Enum.map(tools, & &1["name"])
      refute "_echo" in names
    end
  end

  describe "list/1 — PR-4 submit_slash admin tool" do
    test "submit_slash is exposed for non-diagnostic role" do
      tools = Tools.list("dev")
      names = Enum.map(tools, & &1["name"])
      assert "submit_slash" in names
    end

    test "submit_slash is exposed for diagnostic role" do
      tools = Tools.list("diagnostic")
      names = Enum.map(tools, & &1["name"])
      assert "submit_slash" in names
    end

    test "submit_slash schema requires `command` string" do
      submit = Tools.list("dev") |> Enum.find(&(&1["name"] == "submit_slash"))
      assert is_map(submit)

      schema = submit["inputSchema"]
      assert schema["type"] == "object"

      props = schema["properties"]
      assert is_map(props["command"])
      assert props["command"]["type"] == "string"

      assert schema["required"] == ["command"]
    end
  end
end
