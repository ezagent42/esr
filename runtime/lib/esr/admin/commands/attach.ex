defmodule Esr.Admin.Commands.Attach do
  @moduledoc """
  `/attach` slash command (PR-22). Resolves the live session in the
  current chat/thread and returns a clickable browser URL backed by
  `EsrWeb.AttachLive` (xterm.js).

  Reads from args:
    * `chat_id` — Feishu chat id
    * `app_id`  — adapter instance id
    * `thread_id` — thread id (or chat_id when not in a thread)

  Returns a Feishu-renderable string carrying both the operator-friendly
  HTTP URL and the canonical `esr://` URI. The HTTP path mirrors URI
  path segments (PR-22 rule: HTTP path = URI path).
  """

  @behaviour Esr.Role.Control

  alias Esr.SessionRegistry
  alias Esr.Uri, as: EsrUri

  @impl true
  def execute(%{"args" => args}) do
    chat_id = Map.get(args, "chat_id", "")
    app_id = Map.get(args, "app_id", "")
    thread_id = Map.get(args, "thread_id", "")

    case SessionRegistry.lookup_by_chat_thread(chat_id, app_id, thread_id) do
      {:ok, sid, _refs} ->
        uri = EsrUri.build_path(["sessions", sid, "attach"], "localhost")
        http_url = EsrUri.to_http_url(uri, EsrWeb.Endpoint)

        {:ok,
         %{
           "text" =>
             "🖥 attach: [#{http_url}](#{http_url})\n" <>
               "uri: `#{uri}`"
         }}

      :not_found ->
        {:ok,
         %{
           "text" => "no live session in this chat. start one with /new-session first"
         }}
    end
  end

  def execute(_cmd), do: {:ok, %{"text" => "🖥 (no args)"}}
end
