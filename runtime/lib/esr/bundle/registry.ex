defmodule Esr.Bundle.Registry do
  @moduledoc """
  ETS-backed registry of installed bundles, keyed by bundle name.

  Mirrors the `Esr.Channel.Registry` pattern (Phase 1): the GenServer
  owns the ETS table lifecycle; reads (`lookup/1`, `list_all/0`) are
  ETS-direct, no GenServer hop.

  Spec: `docs/superpowers/specs/2026-05-10-session-template-and-channel.md`
  §5.3 + §5.5. Phase 4 (Task 4.3).

  ## What lives here

  Each entry is `%{manifest: %Esr.Bundle.Manifest{}, source_path: Path.t()}`
  keyed by the bundle's name (the `name:` field from `manifest.yaml`,
  which is also the directory name for in-tree bundles).

  Distinct from `Esr.SessionTemplate.Registry`: this registry holds
  bundle **metadata** (the manifest + where it came from). The session
  template body itself lives in SessionTemplate.Registry, keyed by the
  template's own name (which can differ from the bundle name when
  e.g. an external bundle dir is named differently from the template
  yaml's `name:`).

  ## API

    * `register/3` — `name`, `manifest`, `source_path`. Idempotent.
    * `lookup/1` — `{:ok, %{manifest, source_path}}` | `:not_found`
    * `list_all/0` — `[bundle_name :: String.t()]`
    * `unregister/1` — for `/plugin:disable`.
    * `clear/0` — test helper.
  """

  use GenServer

  @table :esr_bundles

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "Register a bundle. Idempotent: re-registering the same name overwrites."
  @spec register(String.t(), Esr.Bundle.Manifest.t(), Path.t()) :: :ok
  def register(name, manifest, source_path)
      when is_binary(name) and is_binary(source_path) do
    :ets.insert(@table, {name, %{manifest: manifest, source_path: source_path}})
    :ok
  end

  @doc "Look up a bundle by name."
  @spec lookup(String.t()) ::
          {:ok, %{manifest: Esr.Bundle.Manifest.t(), source_path: Path.t()}} | :not_found
  def lookup(name) when is_binary(name) do
    case :ets.lookup(@table, name) do
      [{^name, value}] -> {:ok, value}
      [] -> :not_found
    end
  end

  @doc "Return every registered bundle name."
  @spec list_all() :: [String.t()]
  def list_all do
    :ets.tab2list(@table) |> Enum.map(&elem(&1, 0))
  end

  @doc "Remove a bundle from the registry. Used by /plugin:disable."
  @spec unregister(String.t()) :: :ok
  def unregister(name) when is_binary(name) do
    :ets.delete(@table, name)
    :ok
  end

  @doc "Clear all registered bundles. Used by tests."
  @spec clear() :: :ok
  def clear do
    if :ets.whereis(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end

    :ok
  end
end
