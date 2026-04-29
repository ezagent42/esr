defmodule Esr.Users.Registry do
  @moduledoc """
  ETS-backed snapshot of the esr-user table loaded from `users.yaml`.

  Two ETS indexes (PR-21a):
  - `:esr_users_by_name` — `username → %User{}`
  - `:esr_users_by_feishu_id` — `feishu_id → username`

  The latter lets the inbound-message envelope construction translate
  `<channel user_id="ou_…">` into the canonical esr username in O(1).
  Multiple feishu ids per user are supported (a single human can use
  more than one feishu app); the schema uses a list (`feishu_ids:`)
  and the loader inserts one row per id.

  Snapshot replacement is atomic (load_snapshot/1 deletes both tables
  and refills) so callers never observe a half-loaded state.
  """
  use GenServer

  @by_name :esr_users_by_name
  @by_feishu_id :esr_users_by_feishu_id

  defmodule User do
    @moduledoc """
    Single esr user row. `feishu_ids` is a list of feishu open_id
    strings; a single human may have multiple (one per registered
    Feishu app — open_ids are app-scoped).
    """
    defstruct [:username, feishu_ids: []]
  end

  # --- Public API ---

  def start_link(_ \\ []),
    do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Replace the full snapshot atomically."
  @spec load_snapshot(%{String.t() => User.t()}) :: :ok
  def load_snapshot(snapshot) when is_map(snapshot) do
    GenServer.call(__MODULE__, {:load, snapshot})
  end

  @doc """
  Look up the esr username bound to a feishu open_id. Returns `:not_found`
  when no binding exists. Used at envelope-construction time on inbound
  messages (PR-21b will wire callers).
  """
  @spec lookup_by_feishu_id(String.t()) :: {:ok, String.t()} | :not_found
  def lookup_by_feishu_id(feishu_id) when is_binary(feishu_id) do
    case :ets.lookup(@by_feishu_id, feishu_id) do
      [{^feishu_id, username}] -> {:ok, username}
      [] -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  @doc "Fetch a single user record by username."
  @spec get(String.t()) :: {:ok, User.t()} | :not_found
  def get(username) when is_binary(username) do
    case :ets.lookup(@by_name, username) do
      [{^username, user}] -> {:ok, user}
      [] -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  @doc "List all registered users. Order is ETS-internal (not sorted)."
  @spec list() :: [User.t()]
  def list do
    :ets.tab2list(@by_name) |> Enum.map(fn {_n, u} -> u end)
  rescue
    ArgumentError -> []
  end

  # --- GenServer ---

  @impl true
  def init(:ok) do
    :ets.new(@by_name, [:named_table, :set, read_concurrency: true])
    :ets.new(@by_feishu_id, [:named_table, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:load, snapshot}, _from, state) do
    :ets.delete_all_objects(@by_name)
    :ets.delete_all_objects(@by_feishu_id)

    Enum.each(snapshot, fn {username, %User{feishu_ids: ids} = user} ->
      :ets.insert(@by_name, {username, user})
      Enum.each(ids, fn id -> :ets.insert(@by_feishu_id, {id, username}) end)
    end)

    {:reply, :ok, state}
  end
end
