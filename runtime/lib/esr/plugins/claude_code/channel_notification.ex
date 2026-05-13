defmodule Esr.Plugins.ClaudeCode.ChannelNotification do
  @moduledoc """
  Pure data transform that turns broadcast envelope payloads into the
  `notifications/claude/channel` MCP params shape consumed by Claude Code's
  experimental `claude/channel` capability.

  Lifted out of `EsrWeb.McpController` ahead of that module's deletion per
  rev-7 of spec `docs/superpowers/specs/2026-05-13-cc-channel-stdio-bridge-design.md`.
  The HTTP SSE controller is being replaced by a Python stdio bridge; the
  payload-building logic is reused by the new bridge and therefore needs to
  survive the controller's removal.

  No behavior change: helpers are byte-identical to the originals in
  `EsrWeb.McpController` (which will be deleted in Phase 6 of the plan).
  """

  require Logger

  alias Esr.Resource.Media.PhaserRegistry

  @doc """
  Build the SSE notifications/claude/channel params from a broadcast envelope.

  For text envelopes (msg_type absent or "text"): passes content + meta
  through unchanged (msg_type and media_uri are internal and not exposed).

  For non-text envelopes (msg_type in ["image", "file", "audio"]): replaces
  content with an attachment stub (e.g. "[image attachment]"), resolves
  media_uri to a local filesystem path via PhaserRegistry.transform/2, and
  includes `kind` (the msg_type) and `path` (the resolved local path) in meta.
  The internal msg_type and media_uri fields are stripped from the
  user-visible meta.

  On phaser resolution failure (bad URI / not_found / wrong_env): emits a
  graceful fallback content string and sets meta.kind; meta.path is absent.
  Logs a warning with the failure reason and URI.

  Per spec 2026-05-08-multimedia-content-protocol-design.md §"Channel meta
  shape" + Inbound flow ⑥.
  """
  @spec build_notification_params(map()) :: %{String.t() => term()}
  def build_notification_params(payload) do
    msg_type = payload["msg_type"]
    media_uri = payload["media_uri"]

    if msg_type in ["image", "file", "audio"] and is_binary(media_uri) do
      build_attachment_params(payload, msg_type, media_uri)
    else
      build_text_params(payload)
    end
  end

  defp build_text_params(payload) do
    meta = take_meta(payload)
    %{"content" => payload["content"] || "", "meta" => meta}
  end

  defp build_attachment_params(payload, kind, uri) do
    base_meta = take_meta(payload)

    case PhaserRegistry.transform(uri, :path) do
      {:ok, path} ->
        meta =
          base_meta
          |> Map.put("kind", kind)
          |> Map.put("path", to_string(path))

        %{"content" => "[#{kind} attachment]", "meta" => meta}

      {:error, reason} ->
        Logger.warning("mcp_controller: phaser transform failed",
          reason: inspect(reason),
          uri: uri,
          kind: kind
        )

        meta = Map.put(base_meta, "kind", kind)
        %{"content" => "[#{kind} attachment unavailable: #{reason_str(reason)}]", "meta" => meta}
    end
  end

  # Extracts the user-visible meta fields from a broadcast envelope.
  # Intentionally excludes internal routing fields: msg_type and media_uri.
  defp take_meta(payload) do
    %{
      "chat_id" => payload["chat_id"],
      "app_id" => payload["app_id"],
      "message_id" => payload["message_id"],
      "user" => payload["user"],
      "ts" => payload["ts"],
      "thread_id" => payload["thread_id"],
      "runtime_mode" => payload["runtime_mode"] || "discussion",
      "source" => payload["source"] || "feishu",
      "user_id" => payload["user_id"],
      "workspace" => payload["workspace"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Enum.into(%{}, fn {k, v} -> {k, to_string(v)} end)
  end

  defp reason_str(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_str(reason), do: inspect(reason)
end
