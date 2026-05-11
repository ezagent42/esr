defmodule Esr.Plugins.ClaudeCode.Mcp.Tools do
  @moduledoc """
  Tool schemas the cc plugin exposes to claude over the HTTP MCP
  transport. Ported verbatim from the deleted `adapters/cc_mcp/src/esr_cc_mcp/tools.py`
  surface — same descriptions, same JSON schemas, same role gating
  for the diagnostic `_echo` tool.

  PR-3.5 (2026-05-05): the schemas live here (Elixir, plugin-owned)
  instead of in a Python sidecar. The HTTP MCP controller's
  `tools/list` handler reads `list/1`; `tools/call` translates the
  invocation into the existing `{:tool_invoke, req_id, tool, args,
  channel_pid, principal_id}` peer message that
  `EsrWeb.ChannelChannel` used to deliver — same dispatch, new
  transport.

  Phase 7 (2026-05-10): every session-scoped tool gains an optional
  `current_session_id` argument. When a CCProcess is attached to
  multiple sessions, the inbound `<channel>` notification carries the
  inbound's session_id; claude is instructed to echo it back on each
  tool call so the runtime routes the response to the right
  `cli:channel/<sid>` topic + `*_chat_proxy`. When omitted, the
  runtime falls back to the chat_id → session lookup it has always
  used.
  """

  @reply %{
    "name" => "reply",
    "description" =>
      "Send a message to the user's chat channel. The user reads the " <>
        "channel, not this session — anything you want them to see must go " <>
        "through this tool. chat_id is from the inbound <channel> tag " <>
        "(opaque token scoped to the active channel). app_id MUST be " <>
        "specified explicitly on every call (no default) — take it from " <>
        "the inbound <channel> tag's app_id, or from a forward request's " <>
        "target app. This is an ESR routing identifier (instance_id), not " <>
        "a channel-native app token. Pass edit_message_id to edit an " <>
        "existing message in-place instead of sending a new one. " <>
        "Production callers should always include reply_to_message_id " <>
        "when the reply is in response to a specific inbound message — " <>
        "the runtime uses it to clean up any delivery-ack reaction the " <>
        "per-IM proxy emitted on receive.",
    "inputSchema" => %{
      "type" => "object",
      "properties" => %{
        "chat_id" => %{
          "type" => "string",
          "description" =>
            "Channel chat ID (opaque token scoped to the active channel)"
        },
        "app_id" => %{
          "type" => "string",
          "description" =>
            "ESR routing identifier (instance_id from adapters.yaml). " <>
              "Required on every call — take it from the inbound <channel> " <>
              "tag's app_id attribute. To forward to a different app, set " <>
              "this to the target app's instance_id."
        },
        "text" => %{"type" => "string", "description" => "Message text"},
        "edit_message_id" => %{
          "type" => "string",
          "description" => "Optional message_id to edit in-place"
        },
        "reply_to_message_id" => %{
          "type" => "string",
          "description" =>
            "Optional message_id of the inbound message this reply " <>
              "responds to. When present, the runtime un-reacts any " <>
              "delivery-ack emoji the per-IM proxy added on inbound " <>
              "receive. Stripped automatically on cross-app reply."
        },
        "current_session_id" => %{
          "type" => "string",
          "description" =>
            "Phase 7 multi-session-per-instance hint. Echo the value " <>
              "from the inbound `<channel>` notification's " <>
              "current_session_id field so the runtime routes this " <>
              "reply to the same session the inbound came from. Omit " <>
              "to fall back to the legacy chat_id → session lookup."
        }
      },
      "required" => ["chat_id", "app_id", "text"]
    }
  }

  @send_file %{
    "name" => "send_file",
    "description" =>
      "Send a file to the user's chat channel. Uploads the local file " <>
        "and sends it as a file message.",
    "inputSchema" => %{
      "type" => "object",
      "properties" => %{
        "chat_id" => %{
          "type" => "string",
          "description" =>
            "Channel chat ID (opaque token scoped to the active channel)"
        },
        "file_path" => %{
          "type" => "string",
          "description" => "Absolute path to local file"
        },
        "current_session_id" => %{
          "type" => "string",
          "description" =>
            "Phase 7 multi-session-per-instance hint. Echo the inbound " <>
              "<channel>'s current_session_id so the runtime routes the " <>
              "upload to the right session. Omit to fall back to legacy " <>
              "chat_id → session lookup."
        }
      },
      "required" => ["chat_id", "file_path"]
    }
  }

  @echo %{
    "name" => "_echo",
    "description" =>
      "DIAGNOSTIC ONLY. Echo a nonce back as a reply to ESR_SELF_CHAT_ID. " <>
        "Gated on workspace `role: diagnostic`.",
    "inputSchema" => %{
      "type" => "object",
      "properties" => %{
        "nonce" => %{"type" => "string", "description" => "Arbitrary token"}
      },
      "required" => ["nonce"]
    }
  }

  # PR-4 (2026-05-11 default-agent + agent-driven-flow plan §5.1):
  # admin operations tool. Lets the operator drive ESR slash commands by
  # asking the agent in natural language (any language) — the agent calls
  # `submit_slash` with the literal slash string, which FCP dispatches
  # through `Esr.Entity.SlashHandler` and returns the raw structured
  # result for the agent to interpret.
  @submit_slash %{
    "name" => "submit_slash",
    "description" =>
      "Execute an ESR slash command on behalf of the operator. Use when " <>
        "the user asks (in any language) to perform admin work: adding " <>
        "agents, listing sessions, switching workspace, etc. Returns the " <>
        "structured result map from the command's execute/2 callback " <>
        "(success or {error, %{kind: reason}}). Translate the result into " <>
        "the user's language in your reply.",
    "inputSchema" => %{
      "type" => "object",
      "properties" => %{
        "command" => %{
          "type" => "string",
          "description" =>
            "Full slash command including the leading /, e.g. " <>
              "\"/agent:add type=cc name=helper\" or \"/session:list\"."
        }
      },
      "required" => ["command"]
    }
  }

  @doc """
  Return the tool list the controller advertises in `tools/list`.
  Filtered by workspace role: only `role: diagnostic` workspaces see
  the `_echo` tool.

  `submit_slash` is exposed unconditionally — it's the channel through
  which the agent drives admin operations on behalf of the operator
  (see PR-4 of the 2026-05-11 default-agent plan).
  """
  @spec list(role :: String.t()) :: [map()]
  def list(role \\ "dev")

  def list("diagnostic"),
    do: [@reply, @send_file, @submit_slash, @echo]

  def list(_),
    do: [@reply, @send_file, @submit_slash]
end
