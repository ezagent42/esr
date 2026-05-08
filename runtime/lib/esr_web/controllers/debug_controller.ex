defmodule EsrWeb.DebugController do
  @moduledoc """
  Diagnostic-only controller for PR-24 bidirectional verification.

  Lets us hand-inject a `notification` envelope onto a session's
  `cli:channel/<sid>` PubSub topic via curl, exercising the
  channel→claude path without depending on the Feishu adapter chain
  or a real inbound event.
  """

  use Phoenix.Controller, formats: [:json]

  def inject_notification(conn, %{"sid" => sid} = params) do
    text = Map.get(params, "text", "diagnostic ping from /debug/inject_notification")

    envelope = %{
      "kind" => "notification",
      "source" => "esr-channel",
      "chat_id" => "debug",
      "app_id" => "debug",
      "thread_id" => "",
      "message_id" => "debug-#{System.unique_integer([:positive])}",
      "user" => "ou_debug",
      "user_id" => "ou_debug",
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "content" => text,
      "workspace" => "default"
    }

    Phoenix.PubSub.broadcast(
      EsrWeb.PubSub,
      "cli:channel/" <> sid,
      {:notification, envelope}
    )

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{ok: true, sid: sid, broadcast: envelope}))
  end

  @doc """
  Forward raw bytes to the session's PTY stdin via
  `Esr.Entity.PtyProcess.write/2`. Used by `tools/esr-debug send-keys`
  so debug helpers can drive a TUI without websocat/agent-browser.

  The `text` param is passed straight through; control bytes like
  `\\r`, `\\n`, ESC sequences travel intact. Returns `ok: false` when
  the PTY isn't registered (session ended or never spawned).
  """
  def pty_send(conn, %{"sid" => sid} = params) do
    text = Map.get(params, "text", "")

    {ok, body, status} =
      case Esr.Entity.PtyProcess.write(sid, text) do
        :ok ->
          {true, %{ok: true, sid: sid, bytes: byte_size(text)}, 200}

        {:error, reason} ->
          {false, %{ok: false, sid: sid, error: inspect(reason)}, 404}
      end

    _ = ok

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
