defmodule Esr.Commands.Pty.Attach do
  @moduledoc """
  `/pty:attach pty=<actor_id>` — return a clickable browser URL backed
  by `EsrWeb.PtySocket` (xterm.js). Spec rev-4 §4.2 row `/pty:attach`.

  Phase A.4 migrated PtyProcess's pubsub topic to `pty:<actor_id>`, so
  `actor_id` flows directly into the URL's `?sid=` query param;
  PtySocket subscribes to `pty:<actor_id>` and receives that PTY's
  broadcasts cleanly even when N agents share one session.

  PtySocket auth (signed token) is OUT OF SCOPE per spec rev-2 D3 — the
  URL is unauthenticated; hardening tracked in docs/futures/todo.md
  (key: `pty_attach_security_hardening`).

  Lifts the URL-emitter functionality previously housed in the orphan
  `Esr.Commands.Attach` module (deleted in Phase E.6).
  """

  use Esr.Commands.Meta

  command :pty_attach do
    slash         "/pty:attach"
    category      "PTY"
    description   "返回 PTY 的 web URL；pty=<actor_id>"
    permission    nil
    requires_user_binding      true
    requires_workspace_binding false

    arg :pty, required: true, doc: "PTY actor id"

    error :invalid_args, "/pty:attach requires pty=<actor_id>"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render
  alias Esr.Uri, as: EsrUri

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"submitted_by" => _submitter, "args" => %{"pty" => actor_id}})
      when is_binary(actor_id) and actor_id != "" do
    uri = EsrUri.build_path(["sessions", actor_id, "attach"], "localhost")
    http_url = EsrUri.to_http_url(uri, EsrWeb.Endpoint)

    {:ok,
     %{
       "url" => http_url,
       "uri" => uri,
       "pty" => actor_id,
       "text" => "🖥 attach: [#{http_url}](#{http_url})\nuri: `#{uri}`"
     }}
  end

  def execute(_cmd) do
    Render.error(__MODULE__.command_meta(), :invalid_args)
  end
end
