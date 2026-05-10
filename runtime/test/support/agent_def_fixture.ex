defmodule Esr.TestSupport.AgentDefFixture do
  @moduledoc """
  Test helper: build the canonical `cc` agent_def map directly from
  the legacy `runtime/test/esr/fixtures/agents/simple.yaml` fixture
  (Phase 6 — agents.yaml cache module deleted, but the fixture file
  is retained as a stable shape source).

  Pre-Phase-6 tests called
  `Esr.Entity.Agent.Registry.agent_def("cc")` to get this map. Phase 6
  deletes that registry; this helper provides the same shape directly
  so tests that invoke `Esr.Session.Router.create_session/1` (which
  takes `agent_def` in params) keep working.

  Production callers use `Esr.SessionTemplate.Registry.materialize/2`,
  not this helper — but for direct-invocation integration tests where
  the SessionTemplate setup would be heavy, this is the minimal path.

  ## Why parse the yaml fixture instead of hand-coding the map

  The fixture is the canonical shape source for the cc topology
  pre-Phase-6 (and is retained as test data post-Phase-6). Reading it
  via the parser keeps test fixtures and helpers in lockstep — if a
  future fixture change adds a peer to the inbound chain, helper
  callers see it without code change.
  """

  @doc """
  Build the cc agent_def map. Reads the in-tree
  `runtime/test/esr/fixtures/agents/simple.yaml` fixture and returns
  the same map shape that `Esr.Session.AgentSpawner` consumes.

  Returns `{:ok, agent_def}` on success or `{:error, reason}` on yaml
  parse failure.
  """
  @spec cc_agent_def() :: {:ok, map()} | {:error, term()}
  def cc_agent_def do
    fixture_path =
      Path.expand(
        "../esr/fixtures/agents/simple.yaml",
        __DIR__
      )

    cc_agent_def(fixture_path)
  end

  @doc """
  As `cc_agent_def/0` but reads from an explicit fixture path. Used
  by tests that ship their own fixture (e.g.
  `runtime/test/esr/integration/n2_sessions_test.exs` uses
  `multi_app.yaml`).
  """
  @spec cc_agent_def(Path.t()) :: {:ok, map()} | {:error, term()}
  def cc_agent_def(fixture_path) do
    with {:ok, content} <- File.read(fixture_path),
         {:ok, parsed} <- YamlElixir.read_from_string(content) do
      agents = parsed["agents"] || %{}

      case Map.get(agents, "cc") do
        nil ->
          {:error, {:no_cc_agent, fixture_path}}

        spec ->
          {:ok,
           %{
             description: spec["description"] || "",
             capabilities_required: spec["capabilities_required"] || [],
             pipeline: %{
               inbound: spec["pipeline"]["inbound"] || [],
               outbound: spec["pipeline"]["outbound"] || []
             },
             proxies: spec["proxies"] || [],
             params: spec["params"] || []
           }}
      end
    end
  end
end
