defmodule Esr.Resource.Workspace.Registry do
  @moduledoc """
  In-memory registry of all workspaces (ESR-bound + repo-bound).

  Boot: walks Esr.Paths.workspaces_dir/0 (ESR-bound) and
  Esr.Paths.registered_repos_yaml/0 (repo-bound). Builds name<->id index.
  Rejects duplicate UUIDs loudly.

  Public API for new callers: get_by_id/1, list_names/0, list_all/0,
  delete_by_id/1, rename/2, refresh/0 - all on the new
  Esr.Resource.Workspace.Struct shape.

  Backwards-compatible API for existing callers: get/1 (returns legacy
  Workspace struct), put/1 (accepts both legacy + new struct), list/0
  (legacy structs), workspace_for_chat/2, load_from_file/1 (YAML parse;
  no longer used at boot but kept for tests and migration helpers).

  ## ETS layout

  Two ETS tables coexist for the transition period:

    * :esr_workspaces       - legacy name-keyed table, {name, %Workspace{}}.
      Written by legacy put/1 and refreshed from disk. Old callers that
      do :ets.delete(:esr_workspaces, name) directly still work.

    * :esr_workspaces_uuid  - UUID-keyed table, {uuid, %Struct{}}.
      Written by new-API put/1 and refreshed from disk. Used by all new
      callers (get_by_id/1, list_all/0, etc.).

  Once Phase 7 (describe.ex) and Phase 8 (docs sweep) clean up remaining
  callers, the legacy struct + table can be removed in a follow-up.
  """

  @behaviour Esr.Role.State
  use GenServer
  require Logger

  alias Esr.Paths
  alias Esr.Resource.Workspace.{Struct, FileLoader, JsonWriter, NameIndex, RepoRegistry}

  defmodule Workspace do
    @moduledoc """
    Legacy compat struct preserved for existing callers.
    Internally Registry also stores `%Esr.Resource.Workspace.Struct{}` in a
    separate UUID-keyed table. Conversions live in to_legacy/1 and
    normalize_to_struct/1 in the Registry module.
    """
    defstruct [
      :name,
      :owner,
      role: "dev",
      start_cmd: "",
      chats: [],
      env: %{},
      neighbors: [],
      metadata: %{}
    ]

    @type t :: %__MODULE__{}
  end

  # Legacy name-keyed ETS table (unchanged key strategy for backward compat).
  @legacy_table :esr_workspaces

  # New UUID-keyed ETS table for the new API.
  @uuid_table :esr_workspaces_uuid

  # NameIndex table name (atom passed to all NameIndex calls).
  @name_index_table :esr_workspace_name_index

  ## Public API ----------------------------------------------------------

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  ## NEW public API (UUID-based) -----------------------------------------

  @spec list_names() :: {:ok, [String.t()]}
  def list_names, do: GenServer.call(__MODULE__, :list_names)

  @spec list_all() :: [Struct.t()]
  def list_all, do: GenServer.call(__MODULE__, :list_all)

  @spec get_by_id(String.t()) :: {:ok, Struct.t()} | :not_found
  def get_by_id(id), do: GenServer.call(__MODULE__, {:get_by_id, id})

  @spec delete_by_id(String.t()) :: :ok
  def delete_by_id(id), do: GenServer.call(__MODULE__, {:delete_by_id, id})

  @spec rename(String.t(), String.t()) :: :ok | {:error, term()}
  def rename(old_name, new_name), do: GenServer.call(__MODULE__, {:rename, old_name, new_name})

  @spec refresh() :: :ok | {:error, term()}
  def refresh, do: GenServer.call(__MODULE__, :refresh)

  ## LEGACY public API (still used by callers; deprecated post-Phase-8) --

  @spec get(String.t()) :: {:ok, Workspace.t()} | :error
  def get(name) when is_binary(name) do
    case :ets.lookup(@legacy_table, name) do
      [{^name, ws}] -> {:ok, ws}
      [] -> :error
    end
  end

  @spec put(Workspace.t() | Struct.t()) :: :ok | {:error, term()}
  def put(ws), do: GenServer.call(__MODULE__, {:put, ws})

  @spec list() :: [Workspace.t()]
  def list, do: :ets.tab2list(@legacy_table) |> Enum.map(fn {_n, ws} -> ws end)

  @doc """
  Reverse-lookup the workspace name that owns a given (chat_id, app_id) pair.
  PR-9 T11b.1.

  Iterates every registered workspace and scans its chats list for an exact
  chat_id + app_id match. First match wins. Returns :not_found when no
  workspace binds the pair.
  """
  @spec workspace_for_chat(String.t(), String.t()) :: {:ok, String.t()} | :not_found
  def workspace_for_chat(chat_id, app_id)
      when is_binary(chat_id) and is_binary(app_id) do
    list()
    |> Enum.find_value(:not_found, fn %Workspace{name: name, chats: chats} ->
      if is_list(chats) and chat_matches?(chats, chat_id, app_id) do
        {:ok, name}
      end
    end)
  end

  defp chat_matches?(chats, chat_id, app_id) do
    Enum.any?(chats, fn
      %{"chat_id" => ^chat_id, "app_id" => ^app_id} -> true
      _ -> false
    end)
  end

  @doc """
  Resolve the workspace start_cmd for the given workspace name and
  per-spawn params. Kept for caller compatibility (Esr.Scope.Router).

    * Caller-supplied params[:start_cmd] (atom or string key) wins
      when non-empty.
    * Otherwise falls back to the start_cmd field of the workspace
      registered under workspace_name.
    * Returns nil when neither is set.
  """
  @spec start_cmd_for(String.t(), map()) :: String.t() | nil
  def start_cmd_for(workspace_name, params)
      when is_binary(workspace_name) and is_map(params) do
    raw =
      case get_param(params, :start_cmd) do
        cmd when is_binary(cmd) and cmd != "" ->
          cmd

        _ ->
          case get(workspace_name) do
            {:ok, %{start_cmd: cmd}} when is_binary(cmd) and cmd != "" -> cmd
            _ -> nil
          end
      end

    expand_start_cmd(raw)
  end

  def start_cmd_for(_, _), do: nil

  @doc """
  Parse a workspaces.yaml file and return a map of name => %Workspace{}.

  Preserved for backward compatibility (old callers, ApplicationRestore,
  migration helpers). No longer called at boot - refresh/0 is the new
  boot path which reads workspace.json files instead.
  """
  @spec load_from_file(Path.t()) :: {:ok, map()} | {:error, term()}
  def load_from_file(path) do
    if File.exists?(path) do
      with {:ok, parsed} <- YamlElixir.read_from_file(path) do
        workspaces =
          (parsed["workspaces"] || %{})
          |> Enum.map(fn {name, row} ->
            ws = %Workspace{
              name: name,
              owner: row["owner"] || nil,
              start_cmd: row["start_cmd"] || "",
              role: row["role"] || "dev",
              chats: row["chats"] || [],
              env: row["env"] || %{},
              neighbors: row["neighbors"] || [],
              metadata: row["metadata"] || %{}
            }

            {name, ws}
          end)
          |> Map.new()

        {:ok, workspaces}
      end
    else
      {:ok, %{}}
    end
  end

  ## GenServer callbacks -------------------------------------------------

  @impl GenServer
  def init(_opts) do
    if :ets.info(@legacy_table) == :undefined do
      :ets.new(@legacy_table, [:named_table, :set, :public, read_concurrency: true])
    end

    if :ets.info(@uuid_table) == :undefined do
      :ets.new(@uuid_table, [:named_table, :set, :public, read_concurrency: true])
    end

    ensure_name_index_running()

    case do_refresh() do
      :ok ->
        {:ok, %{}}

      {:error, reason} ->
        Logger.warning(
          "workspace.registry: boot refresh failed (#{inspect(reason)}); starting empty"
        )

        {:ok, %{}}
    end
  end

  @impl GenServer
  def handle_call(:list_names, _from, state),
    do: {:reply, {:ok, list_all_names()}, state}

  def handle_call(:list_all, _from, state),
    do: {:reply, list_all_structs(), state}

  def handle_call({:get_by_id, id}, _from, state),
    do: {:reply, get_struct_by_id(id), state}

  def handle_call({:put, ws}, _from, state) do
    reply = do_put(ws)
    {:reply, reply, state}
  end

  def handle_call({:delete_by_id, id}, _from, state) do
    case :ets.lookup(@uuid_table, id) do
      [{^id, ws}] ->
        :ets.delete(@legacy_table, ws.name)
        NameIndex.delete_by_id(@name_index_table, id)
        :ets.delete(@uuid_table, id)

      [] ->
        :ok
    end

    {:reply, :ok, state}
  end

  def handle_call({:rename, old, new_name}, _from, state) do
    reply = do_rename(old, new_name)
    {:reply, reply, state}
  end

  def handle_call(:refresh, _from, state),
    do: {:reply, do_refresh(), state}

  ## Internals -----------------------------------------------------------

  defp do_refresh do
    :ets.delete_all_objects(@legacy_table)
    :ets.delete_all_objects(@uuid_table)

    # Clear name index
    @name_index_table
    |> NameIndex.all()
    |> Enum.each(fn {_n, id} -> NameIndex.delete_by_id(@name_index_table, id) end)

    esr_bound = scan_esr_bound()
    repo_bound = scan_repo_bound()
    all = esr_bound ++ repo_bound

    case duplicate_uuid(all) do
      nil ->
        Enum.each(all, fn ws ->
          :ets.insert(@uuid_table, {ws.id, ws})
          :ets.insert(@legacy_table, {ws.name, to_legacy(ws)})
          NameIndex.put(@name_index_table, ws.name, ws.id)
        end)

        :ok

      {dup_id, dup_locations} ->
        {:error, {:duplicate_uuid, dup_id, dup_locations}}
    end
  end

  defp scan_esr_bound do
    base = Paths.workspaces_dir()

    if File.exists?(base) do
      base
      |> File.ls!()
      |> Enum.flat_map(fn name ->
        dir = Path.join(base, name)
        path = Path.join(dir, "workspace.json")

        case FileLoader.load(path, location: {:esr_bound, dir}) do
          {:ok, ws} ->
            [ws]

          {:error, reason} ->
            Logger.warning(
              "workspace.registry: skipping #{path} (#{inspect(reason)})"
            )

            []
        end
      end)
    else
      []
    end
  end

  defp scan_repo_bound do
    case RepoRegistry.load(Paths.registered_repos_yaml()) do
      {:ok, repos} ->
        Enum.flat_map(repos, fn entry ->
          path = Paths.workspace_json_repo(entry.path)

          case FileLoader.load(path, location: {:repo_bound, entry.path}) do
            {:ok, ws} ->
              [ws]

            {:error, reason} ->
              Logger.warning(
                "workspace.registry: skipping repo #{entry.path} (#{inspect(reason)})"
              )

              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp duplicate_uuid(workspaces) do
    workspaces
    |> Enum.group_by(& &1.id)
    |> Enum.find(fn {_id, list} -> length(list) > 1 end)
    |> case do
      nil -> nil
      {id, list} -> {id, Enum.map(list, & &1.location)}
    end
  end

  defp list_all_names do
    @name_index_table
    |> NameIndex.all()
    |> Enum.map(fn {n, _id} -> n end)
    |> Enum.sort()
  end

  defp list_all_structs do
    @uuid_table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, ws} -> ws end)
    |> Enum.sort_by(& &1.name)
  end

  defp get_struct_by_id(id) do
    case :ets.lookup(@uuid_table, id) do
      [{^id, ws}] -> {:ok, ws}
      [] -> :not_found
    end
  end

  # do_put dispatches on struct type.
  # Both paths write to both ETS tables for full cross-API consistency.

  defp do_put(%Struct{} = ws) do
    # Upsert: clear any existing entry for this name
    case NameIndex.id_for_name(@name_index_table, ws.name) do
      {:ok, old_id} ->
        :ets.delete(@uuid_table, old_id)
        NameIndex.delete_by_id(@name_index_table, old_id)

      :not_found ->
        :ok
    end

    :ets.delete(@legacy_table, ws.name)
    :ets.insert(@uuid_table, {ws.id, ws})
    :ets.insert(@legacy_table, {ws.name, to_legacy(ws)})

    case NameIndex.put(@name_index_table, ws.name, ws.id) do
      :ok -> write_to_disk(ws)
      {:error, _} = err -> err
    end
  end

  defp do_put(%Workspace{} = legacy) do
    new_struct = normalize_to_struct(legacy)

    # Upsert: clear any existing entry for this name
    case NameIndex.id_for_name(@name_index_table, legacy.name) do
      {:ok, old_id} ->
        :ets.delete(@uuid_table, old_id)
        NameIndex.delete_by_id(@name_index_table, old_id)

      :not_found ->
        :ok
    end

    # Store legacy struct as-is in the legacy table (preserves all fields).
    :ets.insert(@legacy_table, {legacy.name, legacy})
    :ets.insert(@uuid_table, {new_struct.id, new_struct})
    NameIndex.put(@name_index_table, legacy.name, new_struct.id)

    :ok
  end

  defp do_rename(old_name, new_name) do
    with {:ok, id} <- resolve_name(old_name),
         [{^id, ws}] <- :ets.lookup(@uuid_table, id),
         :ok <- NameIndex.rename(@name_index_table, old_name, new_name) do
      new_ws =
        case ws.location do
          {:esr_bound, old_dir} ->
            new_dir = Path.join(Path.dirname(old_dir), new_name)
            :ok = File.rename(old_dir, new_dir)
            %{ws | name: new_name, location: {:esr_bound, new_dir}}

          {:repo_bound, _} ->
            %{ws | name: new_name}
        end

      :ets.insert(@uuid_table, {id, new_ws})
      :ets.delete(@legacy_table, old_name)
      :ets.insert(@legacy_table, {new_name, to_legacy(new_ws)})
      write_to_disk(new_ws)
    end
  end

  defp resolve_name(name) do
    case NameIndex.id_for_name(@name_index_table, name) do
      {:ok, id} -> {:ok, id}
      :not_found -> {:error, :not_found}
    end
  end

  defp write_to_disk(%Struct{location: {:esr_bound, dir}} = ws) do
    JsonWriter.write(Path.join(dir, "workspace.json"), ws)
  end

  defp write_to_disk(%Struct{location: {:repo_bound, repo}} = ws) do
    JsonWriter.write(Paths.workspace_json_repo(repo), ws)
  end

  defp write_to_disk(_), do: :ok

  ## Compat shim helpers -------------------------------------------------

  defp to_legacy(%Struct{} = ws) do
    %Workspace{
      name: ws.name,
      owner: ws.owner,
      role: Map.get(ws.settings, "_legacy.role", "dev"),
      start_cmd: Map.get(ws.settings, "_legacy.start_cmd", ""),
      chats:
        Enum.map(ws.chats, fn c ->
          base = %{
            "chat_id" => c.chat_id,
            "app_id" => c.app_id,
            "kind" => Map.get(c, :kind, "dm")
          }

          # Preserve optional string-key fields (name, metadata) if present.
          extra =
            c
            |> Map.drop([:chat_id, :app_id, :kind])
            |> Enum.flat_map(fn {k, v} when is_atom(k) -> [{Atom.to_string(k), v}]; _ -> [] end)
            |> Map.new()

          Map.merge(base, extra)
        end),
      env: ws.env,
      neighbors: Map.get(ws.settings, "_legacy.neighbors", []),
      metadata: Map.get(ws.settings, "_legacy.metadata", %{})
    }
  end

  defp normalize_to_struct(%Workspace{} = legacy) do
    name = legacy.name

    %Struct{
      id: UUID.uuid4(),
      name: name,
      owner: legacy.owner || "unknown",
      folders: [],
      agent: "cc",
      settings: %{
        "_legacy.role" => legacy.role || "dev",
        "_legacy.start_cmd" => legacy.start_cmd || "",
        "_legacy.neighbors" => legacy.neighbors || [],
        "_legacy.metadata" => legacy.metadata || %{}
      },
      env: legacy.env || %{},
      chats: Enum.map(legacy.chats || [], &normalize_legacy_chat/1),
      transient: false,
      location: {:esr_bound, Paths.workspace_dir(name)}
    }
  end

  defp normalize_legacy_chat(%{"chat_id" => cid, "app_id" => aid} = m) do
    base = %{chat_id: cid, app_id: aid, kind: m["kind"] || "dm"}
    if m["name"], do: Map.put(base, :name, m["name"]), else: base
  end

  # Handle incomplete chats with only chat_id (missing app_id).
  defp normalize_legacy_chat(%{"chat_id" => cid} = m) do
    %{chat_id: cid, app_id: m["app_id"] || "", kind: m["kind"] || "dm"}
  end

  defp normalize_legacy_chat(%{chat_id: _} = m), do: m

  # Fallback: pass through unknown shapes unchanged.
  defp normalize_legacy_chat(other), do: other

  ## start_cmd helpers (legacy Scope.Router compat) ----------------------

  defp expand_start_cmd(nil), do: nil
  defp expand_start_cmd(""), do: nil

  defp expand_start_cmd(cmd) when is_binary(cmd) do
    [head | rest] = String.split(cmd, " ", parts: 2, trim: true)

    head =
      cond do
        String.starts_with?(head, "/") ->
          head

        String.starts_with?(head, "~") ->
          String.replace_prefix(head, "~", System.get_env("HOME") || "")

        true ->
          case System.get_env("ESR_REPO_DIR") do
            repo when is_binary(repo) and repo != "" -> Path.join(repo, head)
            _ -> head
          end
      end

    Enum.join([head | rest], " ")
  end

  defp get_param(params, key) when is_atom(key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end

  ## NameIndex lifecycle -------------------------------------------------

  defp ensure_name_index_running do
    server = name_index_server()

    unless Process.whereis(server) do
      case NameIndex.start_link(table: @name_index_table) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end
  end

  # Must match NameIndex.name_for/1: :"#{__MODULE__}.#{table}"
  # Module name interpolated as string yields "Esr.Resource.Workspace.NameIndex"
  # (no Elixir. prefix) so the composed atom is:
  # :"Esr.Resource.Workspace.NameIndex.esr_workspace_name_index"
  defp name_index_server,
    do: :"Esr.Resource.Workspace.NameIndex.#{@name_index_table}"
end
