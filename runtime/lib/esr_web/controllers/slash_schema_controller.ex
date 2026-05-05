defmodule EsrWeb.SlashSchemaController do
  @moduledoc """
  Phase 2 PR-2.1: schema dump endpoint serving the registered slash
  routes as JSON.

  Single source of truth for downstream consumers:
    - escript (`esr describe-slashes`) generates dynamic CLI subcommands
      from this dump (cached locally for offline use).
    - REPL autocomplete tree.
    - External doc generation (replaces `gen-docs.sh` slash extraction).

  ## Routes
    - `GET /admin/slash_schema.json` — public; emits kinds/args/descriptions/
      categories. `permission` and `command_module` fields are stripped.
    - `GET /admin/slash_schema.json?include_internal=1` — adds permission
      strings and command_module. Same dump, more fields.

  ## Auth
    Today: open. The public form (no `?include_internal`) reveals only
    operator-facing kinds/args — same information `/help` shows in chat.
    The `?include_internal=1` form leaks privilege boundaries; spec §七
    open-question recommends a token gate before exposing it on a
    non-localhost interface. Phase 2 keeps both open in dev; gate
    decision deferred to post-Phase-3 channel-abstraction PR.
  """

  use Phoenix.Controller, formats: [:json]

  def show(conn, params) do
    include_internal = Map.get(params, "include_internal") in ["1", "true", "yes"]

    schema = Esr.Resource.SlashRoute.Registry.dump(include_internal: include_internal)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(schema))
  end
end
