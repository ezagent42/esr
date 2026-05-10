defmodule Esr.Plugin.AgentKindRegistry do
  @moduledoc """
  ETS-backed registry mapping `<plugin>.<agent_kind_name>` → agent kind
  spec. Populated at plugin boot (`Esr.Plugin.Loader` reads each
  plugin's `manifest.yaml` `agent_kinds:` block); read concurrently by
  SessionTemplate's `AgentDefBuilder`, `Esr.Application`'s handler
  bootstrap, `Esr.Interface.Spawner` consumers, and
  `/plugin:agent-types`.

  Replaces `Esr.Entity.Agent.Registry` (the old agents.yaml cache —
  removed in Phase 6 of the SessionTemplate + Channel migration).

  Public read API (`lookup/1`, `list_kinds/0`, `list_kinds_for_plugin/1`,
  `find_unqualified/1`) is ETS-direct, no GenServer hop. The GenServer
  only owns the ETS table lifecycle.

  Mirrors `Esr.Channel.Registry` (line-for-line same shape) — both serve
  the same role for two sibling registry types (channels vs agent
  kinds), populated from the same plugin manifest at the same boot
  step.

  Spec: 2026-05-10-session-template-and-channel.md, Phase 6.
  """

  use GenServer

  @table :esr_plugin_agent_kinds

  @typedoc """
  Agent-kind spec stored under each `<plugin>.<kind_name>` key.

  Mirrors the agent_def shape consumed by `Esr.Session.AgentSpawner`'s
  walker: `pipeline.inbound`, `pipeline.outbound`, `capabilities_required`,
  `proxies`, `params`. The `handler_module` field surfaces the Python
  sidecar handler module name when the kind ships its own one (used by
  `Esr.Application.extract_handler_modules/0`).
  """
  @type spec :: %{
          plugin: String.t(),
          name: String.t(),
          description: String.t(),
          handler_module: String.t() | nil,
          pipeline: %{
            inbound: [%{String.t() => term()}],
            outbound: [String.t()]
          },
          proxies: [%{String.t() => term()}],
          capabilities_required: [String.t()],
          params: [map()]
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Register an agent kind. `key` is `<plugin>.<kind_name>`. Idempotent:
  re-registering the same key replaces the spec (used by
  `/plugin:reload`).
  """
  @spec register(String.t(), String.t(), spec()) :: :ok
  def register(plugin, kind_name, spec)
      when is_binary(plugin) and is_binary(kind_name) and is_map(spec) do
    :ets.insert(@table, {"#{plugin}.#{kind_name}", spec})
    :ok
  end

  @doc """
  Look up an agent kind by qualified `<plugin>.<kind_name>`. Returns
  `{:ok, spec}` on hit, `:not_found` on miss.
  """
  @spec lookup(String.t()) :: {:ok, spec()} | :not_found
  def lookup(key) when is_binary(key) do
    case :ets.lookup(@table, key) do
      [{^key, spec}] -> {:ok, spec}
      [] -> :not_found
    end
  end

  @doc """
  Find an agent kind by an unqualified short name (no `.`). Searches
  every registered key for a kind whose `name` field matches `short_name`.
  Returns `{:ok, qualified_key, spec}` on a single hit, `:not_found` on
  zero hits, and `{:error, {:ambiguous, [key1, key2, ...]}}` on more
  than one — let-it-crash policy: if two plugins both declare a `cc`
  kind, the call site must qualify.

  Used by `Esr.Interface.Spawner` consumers that historically passed
  unqualified `"cc"` (the legacy agents.yaml world had no plugin
  prefix). New callers should always pass the qualified key directly.
  """
  @spec find_unqualified(String.t()) ::
          {:ok, String.t(), spec()} | :not_found | {:error, {:ambiguous, [String.t()]}}
  def find_unqualified(short_name) when is_binary(short_name) do
    matches =
      :ets.tab2list(@table)
      |> Enum.filter(fn {_key, %{name: name}} -> name == short_name end)

    case matches do
      [] -> :not_found
      [{key, spec}] -> {:ok, key, spec}
      multi -> {:error, {:ambiguous, Enum.map(multi, fn {k, _} -> k end)}}
    end
  end

  @doc """
  Return every registered `{<plugin>.<kind_name>, spec}` pair.
  """
  @spec list_kinds() :: [{String.t(), spec()}]
  def list_kinds do
    :ets.tab2list(@table)
  end

  @doc """
  Return every `{key, spec}` pair contributed by `plugin_name`.
  """
  @spec list_kinds_for_plugin(String.t()) :: [{String.t(), spec()}]
  def list_kinds_for_plugin(plugin_name) when is_binary(plugin_name) do
    :ets.tab2list(@table)
    |> Enum.filter(fn {_key, %{plugin: p}} -> p == plugin_name end)
  end

  @doc """
  Return every registered kind name, qualified `<plugin>.<kind>`,
  sorted. Replaces `Esr.Entity.Agent.Registry.list_agents/0` (which
  returned bare names from a single-namespace yaml).
  """
  @spec list_keys() :: [String.t()]
  def list_keys do
    :ets.tab2list(@table)
    |> Enum.map(fn {key, _spec} -> key end)
    |> Enum.sort()
  end

  @doc "Clear all registered kinds. Used by tests + plugin reload."
  @spec clear() :: :ok
  def clear do
    if :ets.whereis(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end

    :ok
  end
end
