defmodule Esr.Persistence.Ets do
  @moduledoc """
  ETS-backed actor-state store with disk checkpoint + reload (PRD 01
  F18, spec §3.1).

  The table is created in `init/1` and lives for the life of the
  GenServer. On `save_to_disk/2` it is serialised via
  `:erlang.term_to_binary/1` and atomically written. On Application
  start, `load_from_disk/2` re-hydrates the table from the file so
  BEAM `kill -9` recovery (Track G-4) can continue with the actor
  states it had at last checkpoint.

  Public API:
    start_link(opts)                  — opts :table (required), :name
    put(table, actor_id, state)       — upsert
    get(table, actor_id)              — {:ok, state} | :error
    delete(table, actor_id)           — :ok
    clear(table)                      — :ok  (simulates fresh boot)
    save_to_disk(table, path)         — :ok
    load_from_disk(table, path)       — {:ok, loaded_count}
  """

  use GenServer

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec put(atom(), String.t(), any()) :: :ok
  def put(table, actor_id, state) when is_binary(actor_id) do
    :ets.insert(table, {actor_id, state})
    :ok
  end

  @spec get(atom(), String.t()) :: {:ok, any()} | :error
  def get(table, actor_id) when is_binary(actor_id) do
    case :ets.lookup(table, actor_id) do
      [{^actor_id, state}] -> {:ok, state}
      [] -> :error
    end
  end

  @spec delete(atom(), String.t()) :: :ok
  def delete(table, actor_id) when is_binary(actor_id) do
    :ets.delete(table, actor_id)
    :ok
  end

  @spec clear(atom()) :: :ok
  def clear(table) do
    :ets.delete_all_objects(table)
    :ok
  end

  @doc """
  Serialise every `{actor_id, state}` pair to disk. Writes to
  `<path>.tmp` then renames atomically so a crash mid-write leaves
  the prior checkpoint intact.
  """
  @spec save_to_disk(atom(), String.t()) :: :ok | {:error, File.posix()}
  def save_to_disk(table, path) do
    entries = :ets.tab2list(table)
    tmp = path <> ".tmp"
    File.mkdir_p!(Path.dirname(path))

    with :ok <- File.write(tmp, :erlang.term_to_binary(entries)) do
      File.rename(tmp, path)
    end
  end

  @doc """
  Load entries from disk into the table. If the file is missing
  returns `{:ok, 0}` (not an error — a fresh instance has no
  checkpoint yet).
  """
  @spec load_from_disk(atom(), String.t()) :: {:ok, non_neg_integer()}
  def load_from_disk(table, path) do
    case File.read(path) do
      {:ok, bin} ->
        entries = :erlang.binary_to_term(bin)
        for {actor_id, state} <- entries, do: :ets.insert(table, {actor_id, state})
        {:ok, length(entries)}

      {:error, :enoent} ->
        {:ok, 0}

      {:error, _} = err ->
        err
    end
  end

  # ------------------------------------------------------------------
  # GenServer
  # ------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    table_name = Keyword.fetch!(opts, :table)
    :ets.new(table_name, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    {:ok, %{table: table_name}}
  end
end
