defmodule Esr.SessionTemplate.FlowNodeRegistry do
  @moduledoc """
  ETS-backed registry of built-in flow nodes that templates can
  reference by name from `flow.inbound[].pipeline:` entries.

  Spec: `docs/superpowers/specs/2026-05-10-session-template-and-channel.md`
  §9 "Built-in flow nodes" + §5.3 template `flow.inbound[].pipeline:` shape.

  ## What's a flow node?

  A flow node is one stage of an inbound pipeline. Two kinds today:

    1. **Built-in routers**: literal-string tokens like `<route_to_agent>`,
       resolved at parse time to an internal sentinel atom. The actual
       routing logic lives in core / future flow runner.
    2. **Module references**: e.g. `Esr.Entity.Agent.MentionParser` —
       resolved by name to a real Elixir module that implements the
       (future) flow-node behaviour.

  This Phase 4 registry is the resolution table for both kinds.

  ## Lifecycle

  Started under `Esr.Application`. `register_builtins/0` is called at
  init/1; it seeds:

    * `<route_to_agent>` → `:builtin_route_to_agent`
    * `Esr.Entity.Agent.MentionParser` (registered if `Code.ensure_loaded?/1`
      succeeds, which is always in-tree)

  Plugins can later register more via manifest `flow_nodes:` blocks
  (Phase 8). For Phase 4, only the built-ins are seeded.

  ## API

    * `lookup/1` — `String.t() | module()` → `{:ok, term}` | `:not_found`
    * `register/2` — `name`, `value`. Used at boot + from tests.
    * `list/0` — every `{name, value}` pair.
    * `clear/0` — wipe the table (test helper).
  """

  use GenServer

  require Logger

  @table :esr_flow_nodes

  @builtins %{
    "<route_to_agent>" => :builtin_route_to_agent
  }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    seed_builtins()
    {:ok, %{}}
  end

  defp seed_builtins do
    for {name, value} <- @builtins do
      :ets.insert(@table, {name, value})
    end

    # Module-named built-in: MentionParser, registered if loadable.
    if Code.ensure_loaded?(Esr.Entity.Agent.MentionParser) do
      :ets.insert(@table, {"Esr.Entity.Agent.MentionParser", Esr.Entity.Agent.MentionParser})
    end

    :ok
  end

  @doc """
  Look up a flow node by its template-string name. Built-in router
  tokens use the literal `<...>` form; module-named nodes use the
  Elixir module name as a string.
  """
  @spec lookup(String.t()) :: {:ok, term()} | :not_found
  def lookup(name) when is_binary(name) do
    case :ets.lookup(@table, name) do
      [{^name, value}] -> {:ok, value}
      [] -> :not_found
    end
  end

  @doc "Register a flow node. Used by `init/1` and by plugin loaders."
  @spec register(String.t(), term()) :: :ok
  def register(name, value) when is_binary(name) do
    :ets.insert(@table, {name, value})
    :ok
  end

  @doc "Return every registered `{name, value}` pair."
  @spec list() :: [{String.t(), term()}]
  def list do
    :ets.tab2list(@table)
  end

  @doc "Test helper — wipe the registry."
  @spec clear() :: :ok
  def clear do
    if :ets.whereis(@table) != :undefined do
      :ets.delete_all_objects(@table)
      seed_builtins()
    end

    :ok
  end
end
