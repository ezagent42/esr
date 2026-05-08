defmodule Esr.Entity.Agent.Instance do
  @moduledoc """
  An agent instance within a session.

  Fields:
    * `id` — UUID v4, stable identity for this instance.
    * `session_id` — UUID of the owning session.
    * `type` — agent type string declared in a plugin manifest (e.g. `"cc"`).
    * `name` — operator-chosen display name; globally unique within the session
      regardless of type (spec §3, Q7=B).
    * `config` — plugin-specific configuration map (validated against plugin's
      `config_schema:` in Phase 7).
    * `created_at` — ISO 8601 string, set at creation.
    * `actor_ids` — `%{cc: <uuid>, pty: <uuid>}`. Persisted at `add_instance_and_spawn/2` so `/claude_code:tui` (and any future agent-name → PTY-id lookup) resolves without a side-channel return.
  """

  @type t :: %__MODULE__{
          id: String.t() | nil,
          session_id: String.t() | nil,
          type: String.t() | nil,
          name: String.t() | nil,
          config: map(),
          created_at: String.t() | nil,
          actor_ids: %{cc: String.t(), pty: String.t()} | nil
        }

  defstruct [
    :id,
    :session_id,
    :type,
    :name,
    :created_at,
    :actor_ids,
    config: %{}
  ]
end
