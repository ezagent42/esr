defmodule Esr.Resource.SlashRoute.Registry do
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
      command_module}`. Used by `Esr.Slash.QueueWatcher` for
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

  @doc """
  List all internal-only routes (kinds in `internal_kinds:` that are
  NOT also exposed under `slashes:`). Used by the schema dump's
  `internal_kinds` section. Sorted by kind.
  """
  @spec list_internal_kinds() :: [map()]
  def list_internal_kinds do
    slash_kinds =
      :ets.tab2list(@slash_table)
      |> MapSet.new(fn {_key, route} -> route.kind end)

    :ets.tab2list(@kind_table)
    |> Enum.map(fn {_kind, route} -> route end)
    |> Enum.reject(fn route -> MapSet.member?(slash_kinds, route.kind) end)
    |> Enum.uniq_by(fn route -> route.kind end)
    |> Enum.sort_by(fn route -> route.kind end)
  end

  @doc """
  Emit a JSON-serializable map describing the schema. Single source of
  truth for escript subcommand generation, REPL autocomplete, and any
  external doc tooling.

  Shape:

      %{
        "version" => 1,
        "slashes" => [%{
          "kind" => "session_new",
          "slash" => "/new-session",
          "aliases" => ["/new"],
          "description" => "...",
          "category" => "session",
          "args" => [...],
          "requires_workspace_binding" => true,
          "requires_user_binding" => false,
          # only when include_internal: true
          "permission" => "session.create",
          "command_module" => "Esr.Commands.Session.New"
        }, ...],
        "internal_kinds" => [%{
          "kind" => "grant",
          "description" => "...",
          # only when include_internal: true
          "permission" => "cap.manage",
          "command_module" => "Esr.Commands.Cap.Grant"
        }, ...]
      }

  When `include_internal: false` (the default), the `permission` and
  `command_module` fields are stripped from each entry. The
  `internal_kinds:` section is still listed (kinds, descriptions,
  categories) but operators cannot derive privilege requirements from
  the public dump.
  """
  @spec dump(keyword()) :: map()
  def dump(opts \\ []) do
    include_internal = Keyword.get(opts, :include_internal, false)

    %{
      "version" => 1,
      "slashes" => Enum.map(list_slashes(), &serialize(&1, include_internal)),
      "internal_kinds" => Enum.map(list_internal_kinds(), &serialize(&1, include_internal))
    }
  end

  defp serialize(route, include_internal) do
    base = %{
      "kind" => route.kind,
      "description" => Map.get(route, :description),
      "category" => Map.get(route, :category)
    }

    base =
      case Map.get(route, :slash) do
        nil -> base
        slash -> Map.put(base, "slash", slash)
      end

    base =
      case Map.get(route, :aliases, []) do
        [] -> base
        aliases -> Map.put(base, "aliases", aliases)
      end

    base =
      case Map.get(route, :args) do
        nil -> base
        args -> Map.put(base, "args", args)
      end

    base =
      case Map.get(route, :requires_workspace_binding) do
        nil -> base
        v -> Map.put(base, "requires_workspace_binding", v)
      end

    base =
      case Map.get(route, :requires_user_binding) do
        nil -> base
        v -> Map.put(base, "requires_user_binding", v)
      end

    if include_internal do
      base
      |> Map.put("permission", Map.get(route, :permission))
      |> Map.put("command_module", inspect_module(Map.get(route, :command_module)))
    else
      base
    end
  end

  defp inspect_module(nil), do: nil
  defp inspect_module(mod) when is_atom(mod), do: inspect(mod)
  defp inspect_module(other), do: to_string(other)

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

  @doc """
  Register a per-plugin slash-route overlay. `snapshot` has the same
  shape as the one passed to `load_snapshot/1` (`:slashes` + `:internal_kinds`
  lists). Collision against base or any other overlay is a hard error
  — the call returns `{:error, {:slash_collision | :kind_collision, key}}`
  and the overlay is NOT installed.

  Audit #6 / 2026-05-08-plugin-command-registration spec §5.3.
  """
  @spec register_overlay(plugin_name :: String.t(), snapshot :: map()) ::
          :ok | {:error, term()}
  def register_overlay(plugin_name, snapshot)
      when is_binary(plugin_name) and is_map(snapshot) do
    GenServer.call(__MODULE__, {:register_overlay, plugin_name, snapshot})
  end

  @doc """
  Remove the overlay registered by `plugin_name`. Idempotent — removing
  an overlay that was never registered is `:ok`.
  """
  @spec unregister_overlay(plugin_name :: String.t()) :: :ok
  def unregister_overlay(plugin_name) when is_binary(plugin_name) do
    GenServer.call(__MODULE__, {:unregister_overlay, plugin_name})
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
    {:ok, %{base: %{slashes: [], internal_kinds: []}, overlays: %{}}}
  end

  @impl true
  def handle_call({:load, snapshot}, _from, state) do
    base = %{
      slashes: Map.get(snapshot, :slashes, []),
      internal_kinds: Map.get(snapshot, :internal_kinds, [])
    }

    new_state = %{state | base: base}

    case rebuild_merged_view(new_state) do
      :ok ->
        {:reply, :ok, new_state}

      {:error, reason} = err ->
        Logger.error("SlashRoute.Registry: base load produced collision: #{inspect(reason)}")
        {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:register_overlay, plugin_name, snapshot}, _from, state) do
    overlay = %{
      slashes: Map.get(snapshot, :slashes, []),
      internal_kinds: Map.get(snapshot, :internal_kinds, [])
    }

    candidate = %{state | overlays: Map.put(state.overlays, plugin_name, overlay)}

    case rebuild_merged_view(candidate) do
      :ok ->
        {:reply, :ok, candidate}

      {:error, _} = err ->
        # Collision — do NOT install the overlay; rebuild from the
        # pre-call state so the merged ETS reflects the rolled-back view.
        _ = rebuild_merged_view(state)
        {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:unregister_overlay, plugin_name}, _from, state) do
    candidate = %{state | overlays: Map.delete(state.overlays, plugin_name)}
    :ok = rebuild_merged_view(candidate)
    {:reply, :ok, candidate}
  end

  # Rebuild the public ETS tables from base + every overlay. Collision
  # across registrations is a hard error — we refuse to install rather
  # than silently overwrite.
  defp rebuild_merged_view(%{base: base, overlays: overlays}) do
    all_slashes =
      base.slashes ++
        (overlays |> Map.values() |> Enum.flat_map(&Map.get(&1, :slashes, [])))

    all_internal =
      base.internal_kinds ++
        (overlays |> Map.values() |> Enum.flat_map(&Map.get(&1, :internal_kinds, [])))

    # Kind-collision is checked WITHIN slashes and WITHIN internal_kinds
    # separately: the canonical yaml deliberately shares some kinds across
    # both lists (e.g. `cap_grant` is both slash-callable and an
    # internal_kind alias for the escript dispatch path — see
    # priv/slash-routes.default.yaml comment around line 551). The
    # kind_table is populated from both with internal_kinds overwriting,
    # so cross-list kind reuse is by design, not a collision.
    with :ok <- detect_slash_collision(all_slashes),
         :ok <- detect_kind_collision(all_slashes),
         :ok <- detect_kind_collision(all_internal) do
      :ets.delete_all_objects(@slash_table)
      :ets.delete_all_objects(@kind_table)

      Enum.each(all_slashes, fn route ->
        keys = [route.slash | Map.get(route, :aliases, [])]
        Enum.each(keys, fn key -> :ets.insert(@slash_table, {key, route}) end)
        :ets.insert(@kind_table, {route.kind, route})
      end)

      Enum.each(all_internal, fn route -> :ets.insert(@kind_table, {route.kind, route}) end)

      :ok
    end
  end

  defp detect_slash_collision(slashes) do
    keys =
      Enum.flat_map(slashes, fn route ->
        [route.slash | Map.get(route, :aliases, [])]
      end)

    case keys -- Enum.uniq(keys) do
      [] -> :ok
      [dup | _] -> {:error, {:slash_collision, dup}}
    end
  end

  defp detect_kind_collision(routes) do
    kinds = Enum.map(routes, & &1.kind)

    case kinds -- Enum.uniq(kinds) do
      [] -> :ok
      [dup | _] -> {:error, {:kind_collision, dup}}
    end
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
