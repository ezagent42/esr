defmodule Esr.Workspaces.Registry do
  @moduledoc """
  In-memory workspaces.yaml cache populated on esrd startup (spec §3.6).

  GenServer + ETS. Public read via `get/1` or `list/0` without hitting
  the GenServer. Loaded once at boot from
  `~/.esrd/<instance>/workspaces.yaml`; subsequent writes from the
  CLI re-push via `cli:workspace/register` (P3-4).
  """
  use GenServer

  @table :esr_workspaces

  defmodule Workspace do
    @moduledoc """
    Workspace record loaded from yaml.

    `chats` is a list of maps shaped
    `%{"chat_id" => _, "app_id" => _, "kind" => _, "name" => optional,
       "metadata" => optional}`.
    `neighbors` is a list of `<type>:<id>` URI-fragment strings declared
    in yaml; PR-C 2026-04-27 added it for actor-topology-routing.
    `metadata` is a free-form business-topology context map (PR-F
    2026-04-28); operators put fields like `purpose`, `pipeline_position`,
    `hand_off_to` here so the cc_mcp `describe_topology` tool can expose
    them to the LLM verbatim, without code changes.
    """
    defstruct [
      :name, :cwd, :start_cmd, :role, :chats, :env,
      neighbors: [],
      metadata: %{}
    ]
  end

  # --- Public API ---
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec get(String.t()) :: {:ok, Workspace.t()} | :error
  def get(name) when is_binary(name) do
    case :ets.lookup(@table, name) do
      [{^name, ws}] -> {:ok, ws}
      [] -> :error
    end
  end

  @spec list() :: [Workspace.t()]
  def list, do: :ets.tab2list(@table) |> Enum.map(fn {_n, ws} -> ws end)

  @doc """
  Reverse-lookup the workspace name that owns a given `(chat_id, app_id)`
  pair. PR-9 T11b.1.

  Iterates every registered workspace and scans its `chats` list (a list
  of maps shaped `%{"chat_id" => _, "app_id" => _, "kind" => _}` loaded
  from `workspaces.yaml`) for an exact `chat_id` + `app_id` match. First
  match wins. Returns `:not_found` when no workspace binds the pair.

  Symmetric to the Python adapter's `_workspace_of` (see
  `adapters/feishu/src/esr_feishu/adapter.py:_load_workspace_map`). The
  Elixir side needs it for `SessionRouter` to thread `workspace_name`
  into pipeline params at session auto-create time (T11b.2).
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

  @spec put(Workspace.t()) :: :ok
  def put(%Workspace{} = ws), do: GenServer.call(__MODULE__, {:put, ws})

  @spec load_from_file(Path.t()) :: {:ok, map()} | {:error, term()}
  def load_from_file(path) do
    if File.exists?(path) do
      with {:ok, parsed} <- YamlElixir.read_from_file(path) do
        workspaces =
          (parsed["workspaces"] || %{})
          |> Enum.map(fn {name, row} ->
            ws = %Workspace{
              name: name,
              cwd: row["cwd"] || "",
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

  # --- GenServer ---
  @impl GenServer
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @impl GenServer
  def handle_call({:put, %Workspace{name: name} = ws}, _from, state) do
    :ets.insert(@table, {name, ws})
    {:reply, :ok, state}
  end
end
