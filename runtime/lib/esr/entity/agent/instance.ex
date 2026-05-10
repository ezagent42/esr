defmodule Esr.Entity.Agent.Instance do
  @moduledoc """
  An agent instance — a stable, identifiable agent process tree that may
  be attached to one or more sessions (Phase 7: multi-session-per-instance).

  Fields:
    * `id` — UUID v4, stable identity for this instance.
    * `session_ids` — list of UUIDs of every session this instance is
      attached to. Index 0 is the originating session (the one the
      instance was created in via `/agent:add`); subsequent entries are
      added by `/agent:add-session`. v2 schema: minItems = 1.
    * `type` — agent type string declared in a plugin manifest (e.g. `"cc"`).
    * `name` — operator-chosen display name. Globally unique within EACH
      session this instance is attached to (a name collision in any
      attached session blocks attach).
    * `config` — plugin-specific configuration map.
    * `created_at` — ISO 8601 string, set at creation.
    * `actor_ids` — `%{cc: <uuid>, pty: <uuid>}` set at
      `add_instance_and_spawn/2` so `/claude_code:tui` (and any future
      agent-name → PTY-id lookup) resolves without a side-channel return.

  Phase 7 (2026-05-10): the singular `session_id` field was renamed to
  the plural `session_ids` array. The on-disk shape changed from one
  `agents:[]` block per session.json to one file per instance at
  `sessions/<sid>/agents/<instance_uuid>.json`. Migration script:
  `mix esr.migrate_agent_instances_v1_to_v2`.
  """

  @type t :: %__MODULE__{
          id: String.t() | nil,
          session_ids: [String.t()],
          type: String.t() | nil,
          name: String.t() | nil,
          config: map(),
          created_at: String.t() | nil,
          actor_ids: %{cc: String.t(), pty: String.t()} | nil
        }

  defstruct [
    :id,
    :type,
    :name,
    :created_at,
    :actor_ids,
    config: %{},
    session_ids: []
  ]

  @doc """
  Return the originating (primary) session id — the first entry of
  `session_ids`. Used by callers that historically read the singular
  `session_id` field; new code that needs the full attached set should
  read `session_ids` directly.

  Returns `nil` if `session_ids` is empty (transient state only — a
  persisted instance always has ≥ 1 session per the v2 schema).
  """
  @spec primary_session_id(t()) :: String.t() | nil
  def primary_session_id(%__MODULE__{session_ids: [sid | _]}) when is_binary(sid), do: sid
  def primary_session_id(%__MODULE__{}), do: nil

  @doc """
  True iff `session_id` is in this instance's `session_ids` list.
  """
  @spec attached?(t(), String.t()) :: boolean()
  def attached?(%__MODULE__{session_ids: ids}, session_id) when is_binary(session_id),
    do: session_id in ids
end
