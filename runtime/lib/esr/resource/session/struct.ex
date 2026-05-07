defmodule Esr.Resource.Session.Struct do
  @moduledoc """
  In-memory representation of a session, parsed from session.json.

  Fields:
    * `id` — UUID v4, canonical identity (stable for session lifetime).
    * `name` — operator-provided display alias; unique within (owner_user, name). May change.
    * `owner_user` — user UUID of the user who created this session.
    * `workspace_id` — UUID of the workspace this session is bound to.
    * `agents` — ordered list of agent instance maps (%{type, name, config}).
      First entry is the default primary if primary_agent is not set.
    * `primary_agent` — name of the agent receiving un-addressed plain text (Q8=A).
    * `attached_chats` — list of chats with this session in their attached-set.
      Each entry: %{chat_id, app_id, attached_by, attached_at}.
    * `created_at` — ISO 8601 string; set at session creation.
    * `transient` — if true, workspace at sessions/<uuid>/ is pruned when session
      ends and the workspace is clean.
  """

  @type agent_entry :: %{
          required(:type) => String.t(),
          required(:name) => String.t(),
          required(:config) => map()
        }

  @type chat_entry :: %{
          required(:chat_id) => String.t(),
          required(:app_id) => String.t(),
          required(:attached_by) => String.t(),
          required(:attached_at) => String.t()
        }

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          owner_user: String.t() | nil,
          workspace_id: String.t() | nil,
          agents: [agent_entry()],
          primary_agent: String.t() | nil,
          attached_chats: [chat_entry()],
          created_at: String.t() | nil,
          transient: boolean()
        }

  defstruct [
    :id,
    :name,
    :owner_user,
    :workspace_id,
    :primary_agent,
    :created_at,
    agents: [],
    attached_chats: [],
    transient: false
  ]
end
