defmodule Esr.Resource.SlashRouteRegistry do
  @moduledoc """
  ETS-backed snapshot of slash-routes.yaml (PR-21κ, 2026-04-30).

  The yaml has two top-level sections:

    * `slashes:` — slash-callable entries keyed by literal slash text
      (e.g. `"/new-session"`, `"/workspace info"`). Each carries metadata
      for FAA / future Telegram adapters: `kind`, `permission`,
      `command_module`, `requires_workspace_binding`,
      `requires_user_binding`, `category`, `description`, optional
      `aliases`, and `args` schema.

    * `internal_kinds:` — kind-only entries with `{permission,
      command_module}`. Used by `Esr.Admin.CommandQueue.Watcher` for
      CLI-driven commands that never come through slash. Yaml is the
      single source of truth for kind → command mapping.

  Public read API bypasses the GenServer — readers go directly to ETS
  via `:ets.lookup/2`. The GenServer only owns the snapshot (replaces
  it atomically on `load_snapshot/1`).

  See `docs/notes/yaml-authoring-lessons.md` for the canonical
  4-piece subsystem pattern this module follows.
  """

  @behaviour Esr.Role.State

  use GenServer
  require Logger

  @slash_table :esr_slash_routes
  @kind_table :esr_slash_kinds

  # ------------------------------------------------------------------
  # Public read API (ETS-direct, no GenServer hop)
  # ------------------------------------------------------------------

  @doc """
  Resolve a slash text (the operator's literal input, e.g.
  `"/new-session esr-dev name=foo"`) to a route.

  Returns `{:ok, route}` for a known slash, or `:not_found`. Matching
  uses longest-prefix on whitespace boundaries — e.g. text starting
  with `/workspace info` wins over `/workspace`. Aliases resolve to the
  same route as their primary key.
  """
  @spec lookup(String.t()) :: {:ok, map()} | :not_found
  def lookup(text) when is_binary(text) do
    head = slash_head(text)

    # Try multi-word matches first (longest prefix). E.g. "/workspace info ..."
    # before "/workspace".
    keys_in_text(text)
    |> Enum.find_value(:not_found, fn k ->
      case :ets.lookup(@slash_table, k) do
        [{_, route}] -> {:ok, route}
        [] -> nil
      end
    end)
    |> case do
      :not_found ->
        # Fallback: single-word slash like "/help" with arbitrary trailing args.
        case :ets.lookup(@slash_table, head) do
          [{_, route}] -> {:ok, route}
          [] -> :not_found
        end

      hit ->
        hit
    end
  end

  @doc """
  Resolve a kind (string, e.g. `"session_new"`) to its required
  permission. Returns `nil` if no permission is required (e.g.
  `/help`). Returns `:not_found` if the kind is unknown.

  Looks at both `slashes:` and `internal_kinds:` since both feed the
  same Dispatcher.
  """
  @spec permission_for(String.t()) :: String.t() | nil | :not_found
  def permission_for(kind) when is_binary(kind) do
    case :ets.lookup(@kind_table, kind) do
      [{_, %{permission: perm}}] -> perm
      [] -> :not_found
    end
  end

  @doc """
  Resolve a kind to its command module (atom). Returns `:not_found` if
  the kind is unknown.
  """
  @spec command_module_for(String.t()) :: module() | :not_found
  def command_module_for(kind) when is_binary(kind) do
    case :ets.lookup(@kind_table, kind) do
      [{_, %{command_module: mod}}] -> mod
      [] -> :not_found
    end
  end

  @doc """
  Look up the full route map for a kind (slash or internal). Returns
  `{:ok, route}` or `:not_found`.
  """
  @spec route_for_kind(String.t()) :: {:ok, map()} | :not_found
  def route_for_kind(kind) when is_binary(kind) do
    case :ets.lookup(@kind_table, kind) do
      [{_, route}] -> {:ok, route}
      [] -> :not_found
    end
  end

  @doc """
  List all slash-callable routes (used by `/help` rendering).
  Excludes `internal_kinds` entries.
  """
  @spec list_slashes() :: [map()]
  def list_slashes do
    :ets.tab2list(@slash_table)
    |> Enum.map(fn {_key, route} -> route end)
    |> Enum.uniq_by(fn route -> route.kind end)
    |> Enum.sort_by(fn route -> {route[:category] || "其他", route.kind} end)
  end

  # ------------------------------------------------------------------
  # Snapshot API (FileLoader → here)
  # ------------------------------------------------------------------

  @doc """
  Replace the snapshot atomically. `snapshot` is a map with two keys:
    * `:slashes` — list of route maps (each carrying its slash key + aliases)
    * `:internal_kinds` — list of route maps (each carrying its kind name)
  """
  @spec load_snapshot(map()) :: :ok
  def load_snapshot(snapshot) when is_map(snapshot) do
    GenServer.call(__MODULE__, {:load, snapshot})
  end

  # ------------------------------------------------------------------
  # GenServer
  # ------------------------------------------------------------------

  def start_link(_opts \\ []),
    do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@slash_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@kind_table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:load, snapshot}, _from, state) do
    :ets.delete_all_objects(@slash_table)
    :ets.delete_all_objects(@kind_table)

    # Insert each slash-callable entry under all its keys (primary +
    # aliases). Insert each entry's kind into kind_table.
    slashes = Map.get(snapshot, :slashes, [])

    Enum.each(slashes, fn route ->
      keys = [route.slash | Map.get(route, :aliases, [])]
      Enum.each(keys, fn key -> :ets.insert(@slash_table, {key, route}) end)
      :ets.insert(@kind_table, {route.kind, route})
    end)

    # Internal-only kinds populate kind_table only.
    internal = Map.get(snapshot, :internal_kinds, [])
    Enum.each(internal, fn route -> :ets.insert(@kind_table, {route.kind, route}) end)

    {:reply, :ok, state}
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  # First whitespace-separated token. `"/new-session foo"` → `"/new-session"`.
  defp slash_head(text) do
    text
    |> String.trim()
    |> String.split(~r/\s+/, parts: 2, trim: true)
    |> List.first()
  end

  # Multi-word prefix candidates. `"/workspace info abc"` →
  # ["/workspace info abc", "/workspace info", "/workspace"].
  # Walks from longest to shortest so longest-match wins.
  defp keys_in_text(text) do
    parts = text |> String.trim() |> String.split(~r/\s+/, trim: true)

    # Build [["/workspace", "info", "abc"], ["/workspace", "info"], ["/workspace"]]
    # then collapse each back to a string.
    1..length(parts)
    |> Enum.to_list()
    |> Enum.reverse()
    |> Enum.map(fn n -> parts |> Enum.take(n) |> Enum.join(" ") end)
  end
end
