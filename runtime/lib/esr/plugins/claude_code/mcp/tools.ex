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

  @doc """
  Return the tool list the controller advertises in `tools/list`.
  Filtered by workspace role: only `role: diagnostic` workspaces see
  the `_echo` tool.
  """
  @spec list(role :: String.t()) :: [map()]
  def list(role \\ "dev")

  def list("diagnostic"),
    do: [@reply, @send_file, @echo]

  def list(_),
    do: [@reply, @send_file]
end
