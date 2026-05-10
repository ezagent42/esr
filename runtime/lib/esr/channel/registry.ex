defmodule Esr.Channel.Registry do
  @moduledoc """
  ETS-backed registry mapping `<plugin>.<channel_name>` → channel spec.
  Populated at plugin boot (`Esr.Plugin.Loader` reads each plugin's
  `manifest.yaml` `channels:` block); read concurrently by SessionTemplate
  loader during template registration (Phase 4) and by
  `Esr.SessionTemplate.AgentDefBuilder` (Phase 6) during agent_def
  materialization.

  Public read API (`lookup/1`, `lookup_spec/1`, `list_kinds/0`,
  `list_specs/0`) is ETS-direct, no GenServer hop. The GenServer only
  owns the ETS table lifecycle.

  ## Stored value shape

  Phase 1 stored just the module atom. Phase 6 (2026-05-10) widened
  the value to a full spec map so channels can declare their inbound
  peer + proxy contributions to a session's pipeline. Old
  `lookup/1` still returns `{:ok, module}` (extracting `:module` from
  the spec); new callers that need the full shape (e.g.
  `Esr.SessionTemplate.AgentDefBuilder`) use `lookup_spec/1`.

  History: 2026-05-10 spec, Phase 1 + Phase 6.
  """

  use GenServer

  @table :esr_channel_kinds

  @typedoc """
  A channel kind's full registered spec.

  - `:plugin` — owning plugin name
  - `:name` — channel-local name (the second half of the
    `<plugin>.<channel>` key)
  - `:module` — the lifecycle peer module (an `Esr.Channel`-behaving
    GenServer)
  - `:config_schema` — JSON-schema-like map for config validation;
    free-form, channel-impl-specific
  - `:pipeline_contributions` — list of inbound peer maps with
    `"name"` + `"impl"` keys, contributed to a session's
    `pipeline.inbound` when a SessionTemplate references this channel
  - `:proxies` — list of stateless-proxy maps with `"name"` + `"impl"`
    + optional `"target"`, contributed to a session's `proxies` block
  """
  @type spec :: %{
          plugin: String.t(),
          name: String.t(),
          module: module(),
          config_schema: map() | nil,
          pipeline_contributions: [%{String.t() => term()}],
          proxies: [%{String.t() => term()}]
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
  Register a channel kind. `key` is `<plugin>.<channel_name>`.
  Idempotent: re-registering the same key replaces the spec.

  Two arities:

    - `register/3` accepts a bare module atom (Phase 1 shape) for
      back-compat; defaults pipeline_contributions + proxies to `[]`.
    - `register/4` accepts the full spec map carrying optional
      pipeline_contributions + proxies (Phase 6).
  """
  @spec register(String.t(), String.t(), module()) :: :ok
  def register(plugin, channel_name, module)
      when is_binary(plugin) and is_binary(channel_name) and is_atom(module) do
    register(plugin, channel_name, module, %{})
  end

  @spec register(String.t(), String.t(), module(), map()) :: :ok
  def register(plugin, channel_name, module, extras)
      when is_binary(plugin) and is_binary(channel_name) and is_atom(module) and is_map(extras) do
    spec = %{
      plugin: plugin,
      name: channel_name,
      module: module,
      config_schema: Map.get(extras, :config_schema),
      pipeline_contributions: Map.get(extras, :pipeline_contributions, []),
      proxies: Map.get(extras, :proxies, [])
    }

    :ets.insert(@table, {"#{plugin}.#{channel_name}", spec})
    :ok
  end

  @doc """
  Look up the channel kind's lifecycle peer module by
  `<plugin>.<channel_name>`. Returns `{:ok, module}` (the
  Phase-1-compatible shape) on hit, `:not_found` on miss.
  """
  @spec lookup(String.t()) :: {:ok, module()} | :not_found
  def lookup(key) when is_binary(key) do
    case :ets.lookup(@table, key) do
      [{^key, %{module: module}}] -> {:ok, module}
      [{^key, module}] when is_atom(module) -> {:ok, module}
      [] -> :not_found
    end
  end

  @doc """
  Look up the full spec by `<plugin>.<channel_name>`. Returns
  `{:ok, spec}` on hit, `:not_found` on miss. Used by
  `Esr.SessionTemplate.AgentDefBuilder` (Phase 6) which needs the
  pipeline_contributions + proxies fields to materialize an agent_def.
  """
  @spec lookup_spec(String.t()) :: {:ok, spec()} | :not_found
  def lookup_spec(key) when is_binary(key) do
    case :ets.lookup(@table, key) do
      [{^key, %{module: _} = spec}] -> {:ok, spec}
      [{^key, module}] when is_atom(module) ->
        # Phase-1-only legacy entry (bare module). Synthesize a default
        # spec so callers don't have to handle the shape divergence.
        [plugin, name] = String.split(key, ".", parts: 2)

        {:ok,
         %{
           plugin: plugin,
           name: name,
           module: module,
           config_schema: nil,
           pipeline_contributions: [],
           proxies: []
         }}

      [] ->
        :not_found
    end
  end

  @doc """
  Return every registered `{<plugin>.<channel_name>, module}` pair.
  Phase-1-compatible shape (bare module). Use `list_specs/0` for the
  full spec form.
  """
  @spec list_kinds() :: [{String.t(), module()}]
  def list_kinds do
    :ets.tab2list(@table)
    |> Enum.map(fn
      {key, %{module: module}} -> {key, module}
      {key, module} when is_atom(module) -> {key, module}
    end)
  end

  @doc """
  Return every registered `{<plugin>.<channel_name>, spec}` pair with
  the full Phase-6 spec map.
  """
  @spec list_specs() :: [{String.t(), spec()}]
  def list_specs do
    :ets.tab2list(@table)
    |> Enum.map(fn
      {key, %{module: _} = spec} ->
        {key, spec}

      {key, module} when is_atom(module) ->
        [plugin, name] = String.split(key, ".", parts: 2)

        {key,
         %{
           plugin: plugin,
           name: name,
           module: module,
           config_schema: nil,
           pipeline_contributions: [],
           proxies: []
         }}
    end)
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
