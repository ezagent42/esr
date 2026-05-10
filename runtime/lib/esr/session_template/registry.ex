defmodule Esr.SessionTemplate.Registry do
  @moduledoc """
  ETS-backed registry of parsed `Esr.SessionTemplate` structs, keyed by
  the template's `name`.

  Mirrors `Esr.Channel.Registry` + `Esr.Bundle.Registry`: GenServer owns
  the table lifecycle; reads are ETS-direct.

  Spec: `docs/superpowers/specs/2026-05-10-session-template-and-channel.md`
  §5.3, §5.5. Phase 4 (Task 4.3).

  ## Source attribution

  Each entry carries `source: {:bundle, bundle_name}` or `source: :operator`
  so `/plugin:list templates` (future Phase 5+) can attribute templates
  to their origin. Operator ad-hoc templates that override a bundle-shipped
  template overwrite the entry — there's no `:both` state.

  ## API

    * `register/3` — `name`, `%Esr.SessionTemplate{}`, `source: ...`. Idempotent.
    * `lookup/1` — `{:ok, %Esr.SessionTemplate{}}` | `:not_found`
    * `list_all/0` — `[%{name, source}]` for every registered template
    * `unregister/1` — used by Bundle.Loader.unload.
    * `clear/0` — test helper.
  """

  use GenServer

  @table :esr_session_templates

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @type source :: {:bundle, String.t()} | :operator

  @doc """
  Register a parsed template. `opts[:source]` is required.
  Idempotent: re-registering the same name overwrites.
  """
  @spec register(String.t(), Esr.SessionTemplate.t(), keyword()) :: :ok
  def register(name, %Esr.SessionTemplate{} = template, opts) when is_binary(name) do
    source = Keyword.fetch!(opts, :source)
    :ets.insert(@table, {name, %{template: template, source: source}})
    :ok
  end

  @doc "Look up a parsed template by name."
  @spec lookup(String.t()) :: {:ok, Esr.SessionTemplate.t()} | :not_found
  def lookup(name) when is_binary(name) do
    case :ets.lookup(@table, name) do
      [{^name, %{template: template}}] -> {:ok, template}
      [] -> :not_found
    end
  end

  @doc """
  Return `[%{name, source}]` for every registered template. Used by
  `/session:templates` (Phase 5+) for operator listings.
  """
  @spec list_all() :: [%{name: String.t(), source: source()}]
  def list_all do
    :ets.tab2list(@table)
    |> Enum.map(fn {name, %{source: source}} -> %{name: name, source: source} end)
  end

  @doc "Remove a template from the registry. Used by Bundle.Loader.unload."
  @spec unregister(String.t()) :: :ok
  def unregister(name) when is_binary(name) do
    :ets.delete(@table, name)
    :ok
  end

  @doc "Clear all registered templates. Used by tests."
  @spec clear() :: :ok
  def clear do
    if :ets.whereis(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end

    :ok
  end

  @doc """
  Resolve `template_name` and produce an `agent_def`-shaped map suitable
  for `Esr.Session.AgentSpawner.do_create/1`.

  This is the Phase 5 cut-over hook: instead of `Session.New` reading
  from the legacy `Esr.Entity.Agent.Registry.agent_def/1` (the
  agents.yaml cache, dissolved in Phase 6), it builds the same-shaped
  map from the template's declared channels + agents + flow blocks.

  Phase 6 (2026-05-10): the kind → peer/capability mapping is now
  sourced from each plugin's manifest `agent_kinds:` block (registered
  in `Esr.Plugin.AgentKindRegistry`). New agent kinds declare their
  pipeline contributions in their plugin's manifest with no code
  change in `AgentDefBuilder`.

  `runtime_params` carries the `<runtime>` placeholder values:
    * `chat_id`, `app_id`, `principal_id` — Feishu chat context
    * `name` — operator-supplied agent instance name

  Returns `{:ok, agent_def}` on success or `{:error, reason}`. Errors:
    * `:template_not_found` — `template_name` not in registry
    * `{:unsupported_channel_kind, ...}` / `{:unsupported_agent_kind, ...}`
      — template references a kind that no enabled plugin's manifest
      declares (Phase 6 generalization: kinds are looked up against
      `Esr.Channel.Registry` + `Esr.Plugin.AgentKindRegistry`).
  """
  @spec materialize(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def materialize(template_name, runtime_params)
      when is_binary(template_name) and is_map(runtime_params) do
    case lookup(template_name) do
      {:ok, %Esr.SessionTemplate{} = template} ->
        Esr.SessionTemplate.AgentDefBuilder.build(template, runtime_params)

      :not_found ->
        {:error, :template_not_found}
    end
  end
end
