defmodule Esr.Commands.Pty.Attach do
  @moduledoc """
  `/pty:attach pty=<actor_id>` — return a clickable browser URL backed
  by `EsrWeb.PtySocket` (xterm.js). Spec rev-4 §4.2 row `/pty:attach`.

  Phase A.4 migrated PtyProcess's pubsub topic to `pty:<actor_id>`, so
  the bytes flowing through PtySocket are keyed off the actor_id; we
  no longer expose the actor_id in the URL itself though.

  ## URL shape (PR 2026-05-09)

  Today's URL is `/sessions/attach?token=<phoenix_token>`. The token is
  HMAC-signed via `Phoenix.Token.sign/3` under salt `"pty_attach"` using
  the endpoint's `secret_key_base`; `AttachController` and `PtySocket`
  both verify it with `max_age: 600` (10-minute TTL). The actor_id
  itself never appears in the URL — closes the multi-operator
  attach-spoof gap (anyone with the actor_id from a clipboard/screenshot
  leak could previously attach to a live PTY).

  The `esr://` URI returned alongside still embeds the actor_id (it's
  a routing reference, not a credential), as does the `"text"` field
  for human-readable display.

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

  # Salt name is part of the wire contract — must match the value used
  # in `EsrWeb.AttachController` and `EsrWeb.PtySocket` verification.
  @token_salt "pty_attach"

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"submitted_by" => _submitter, "args" => %{"pty" => actor_id}})
      when is_binary(actor_id) and actor_id != "" do
    # The esr:// URI keeps the actor_id (it's a routing reference, not a
    # credential), but the operator-facing HTTP URL drops it entirely
    # and carries only the signed token.
    uri = EsrUri.build_path(["sessions", actor_id, "attach"], "localhost")
    token = Phoenix.Token.sign(EsrWeb.Endpoint, @token_salt, actor_id)
    http_url = EsrWeb.Endpoint.url() <> "/sessions/attach?token=" <> URI.encode_www_form(token)

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
