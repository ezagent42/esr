defmodule Esr.Resource.Workspace.Struct do
  @moduledoc """
  In-memory representation of a workspace, parsed from workspace.json.

  Fields:
    * `id` — UUID v4, canonical identity (never changes during a workspace's life).
    * `name` — display name (operator-visible). May change via `/workspace rename`.
    * `owner` — esr-username; must be in `users.yaml`.
    * `folders` — list of `{path, name?}` entries. Repo-bound workspaces always
      have at least one (the repo itself); ESR-bound may have zero.
    * `agent` — agent_def name (default `"cc"`).
    * `settings` — flat dot-namespaced map (e.g. `cc.model: "claude-opus-4-7"`).
    * `env` — string→string map merged into spawned sessions' env.
    * `chats` — list of `{chat_id, app_id, kind?}` this workspace default-routes for.
    * `transient` — bool; if true, last-session-end auto-removes ESR-bound storage.
    * `location` — internal field, set at load time. One of:
        * `{:esr_bound, dir}` — workspace.json read from `<dir>/workspace.json`
        * `{:repo_bound, repo_path}` — workspace.json read from `<repo_path>/.esr/workspace.json`
  """

  defstruct [
    :id,
    :name,
    :owner,
    folders: [],
    agent: "cc",
    settings: %{},
    env: %{},
    chats: [],
    transient: false,
    location: nil
  ]

  @type folder :: %{required(:path) => String.t(), optional(:name) => String.t()}
  @type chat :: %{required(:chat_id) => String.t(), required(:app_id) => String.t(), optional(:kind) => String.t()}
  @type location :: {:esr_bound, String.t()} | {:repo_bound, String.t()}

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          owner: String.t(),
          folders: [folder()],
          agent: String.t(),
          settings: %{String.t() => any()},
          env: %{String.t() => String.t()},
          chats: [chat()],
          transient: boolean(),
          location: location() | nil
        }

  @doc """
  Returns true iff the workspace struct satisfies the ≥1-folder invariant
  established by spec 2026-05-11-default-agent-and-agent-driven-flow-design.md
  §4.1. Used by JsonWriter.write/2 as a pre-encode gate.
  """
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{folders: folders}) when is_list(folders) and length(folders) >= 1, do: true
  def valid?(%__MODULE__{}), do: false
end
