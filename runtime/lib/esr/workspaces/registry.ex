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
    @moduledoc false
    defstruct [:name, :cwd, :start_cmd, :role, :chats, :env]
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
              env: row["env"] || %{}
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
