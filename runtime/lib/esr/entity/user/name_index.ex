defmodule Esr.Entity.User.NameIndex do
  @moduledoc """
  Bidirectional username↔UUID index for users, backed by two ETS tables.

  Two tables:
    * `:esr_user_name_to_id` — `{username, uuid}`
    * `:esr_user_id_to_name` — `{uuid, username}`

  Mirrors `Esr.Resource.Workspace.NameIndex` exactly, scoped to users.
  Owned by `Esr.Entity.User.Registry` GenServer; ETS table is configurable
  for test isolation.
  """

  use GenServer

  @default_table :esr_user_name_index

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts,
      name: name_for(Keyword.get(opts, :table, @default_table))
    )
  end

  defp name_for(table), do: :"#{__MODULE__}.#{table}"

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, @default_table)
    name_to_id = :ets.new(:"#{table}_name_to_id", [:named_table, :set, :public, read_concurrency: true])
    id_to_name = :ets.new(:"#{table}_id_to_name", [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table, name_to_id: name_to_id, id_to_name: id_to_name}}
  end

  @spec put(atom(), String.t(), String.t()) :: :ok | {:error, :name_exists | :id_exists}
  def put(table \\ @default_table, name, id) do
    name_to_id = :"#{table}_name_to_id"
    id_to_name = :"#{table}_id_to_name"

    cond do
      :ets.lookup(name_to_id, name) != [] -> {:error, :name_exists}
      :ets.lookup(id_to_name, id) != [] -> {:error, :id_exists}
      true ->
        :ets.insert(name_to_id, {name, id})
        :ets.insert(id_to_name, {id, name})
        :ok
    end
  end

  @spec id_for_name(atom(), String.t()) :: {:ok, String.t()} | :not_found
  def id_for_name(table \\ @default_table, name) do
    case :ets.lookup(:"#{table}_name_to_id", name) do
      [{^name, id}] -> {:ok, id}
      [] -> :not_found
    end
  end

  @spec name_for_id(atom(), String.t()) :: {:ok, String.t()} | :not_found
  def name_for_id(table \\ @default_table, id) do
    case :ets.lookup(:"#{table}_id_to_name", id) do
      [{^id, name}] -> {:ok, name}
      [] -> :not_found
    end
  end

  @spec rename(atom(), String.t(), String.t()) :: :ok | {:error, :not_found | :name_exists}
  def rename(table \\ @default_table, old_name, new_name) do
    name_to_id = :"#{table}_name_to_id"
    id_to_name = :"#{table}_id_to_name"

    case :ets.lookup(name_to_id, old_name) do
      [] ->
        {:error, :not_found}

      [{^old_name, id}] ->
        if :ets.lookup(name_to_id, new_name) != [] do
          {:error, :name_exists}
        else
          :ets.delete(name_to_id, old_name)
          :ets.insert(name_to_id, {new_name, id})
          :ets.insert(id_to_name, {id, new_name})
          :ok
        end
    end
  end

  @spec delete_by_id(atom(), String.t()) :: :ok
  def delete_by_id(table \\ @default_table, id) do
    id_to_name = :"#{table}_id_to_name"
    name_to_id = :"#{table}_name_to_id"

    case :ets.lookup(id_to_name, id) do
      [{^id, name}] ->
        :ets.delete(id_to_name, id)
        :ets.delete(name_to_id, name)
        :ok

      [] ->
        :ok
    end
  end

  @spec all(atom()) :: [{String.t(), String.t()}]
  def all(table \\ @default_table) do
    :ets.tab2list(:"#{table}_name_to_id")
  end
end
