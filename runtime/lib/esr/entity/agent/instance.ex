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
  """

  @type t :: %__MODULE__{
          id: String.t() | nil,
          session_id: String.t() | nil,
          type: String.t() | nil,
          name: String.t() | nil,
          config: map(),
          created_at: String.t() | nil
        }

  defstruct [
    :id,
    :session_id,
    :type,
    :name,
    :created_at,
    config: %{}
  ]
end
