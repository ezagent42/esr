defmodule Esr.Resource.CapabilityPhase6SnapshotTest do
  @moduledoc """
  Cap-source migration acceptance test (Phase 6 invariant gate, spec
  task 6.5).

  Pre-Phase-6 the `agent_def.capabilities_required` field came from
  `Esr.Entity.Agent.Registry` (the agents.yaml cache). Post-Phase-6
  it's composed by `Esr.SessionTemplate.AgentDefBuilder` from each
  enabled plugin's manifest `agent_kinds[].capabilities_required`
  block.

  Per CLAUDE.md memory `feedback_completion_requires_invariant_test`:
  this is the invariant test that proves Phase 6 didn't lose
  cap-resolution semantics. It pins the resolved cap set for the
  canonical feishu-cc topology to a byte-identical literal — any
  unexpected drift here means the migration changed observable
  behaviour.

  ## Snapshot baseline

  The capabilities below are sourced from
  `runtime/test/esr/fixtures/agents/simple.yaml` (the canonical
  pre-Phase-6 `cc` agent fixture). The same three caps appear
  verbatim in `runtime/lib/esr/plugins/claude_code/manifest.yaml`'s
  new `agent_kinds[0].capabilities_required` block. If a future
  refactor changes the cap shape, update the BASELINE_CAPS literal
  here AND the fixture/manifest in lockstep.
  """
  use ExUnit.Case, async: false

  alias Esr.SessionTemplate
  alias Esr.SessionTemplate.AgentDefBuilder

  @baseline_caps [
    "session:default/create",
    "pty:default/spawn",
    "handler:cc_adapter_runner/invoke"
  ]

  defp feishu_cc_template do
    %SessionTemplate{
      schema_version: 1,
      name: "feishu-cc",
      description: "Feishu chat → Claude Code agent",
      dependencies: %{plugins: ["feishu", "claude_code"], bundles: []},
      channels: [
        %{alias: "in", kind: "feishu.chat_proxy", config: %{}},
        %{alias: "cc_mcp", kind: "claude_code.mcp_http", config: %{}}
      ],
      agents: [
        %{kind: "claude_code.cc", name: "alice", consumes: ["cc_mcp"]}
      ],
      flow: %{inbound: [], outbound: []}
    }
  end

  setup do
    case start_supervised(Esr.Channel.Registry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case start_supervised(Esr.Plugin.AgentKindRegistry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    Esr.Channel.Registry.clear()
    Esr.Plugin.AgentKindRegistry.clear()

    # Mirror what Esr.Plugin.Loader does at boot when feishu +
    # claude_code plugins are enabled: register the channels +
    # agent_kinds from their manifests. We use the manifest parser
    # directly so the test stays load-bearing on the manifest's
    # capabilities_required field — if someone hand-edits the manifest
    # to drop a cap, the test fails.
    feishu_manifest_path =
      Path.expand("../../../lib/esr/plugins/feishu/manifest.yaml", __DIR__)

    cc_manifest_path =
      Path.expand("../../../lib/esr/plugins/claude_code/manifest.yaml", __DIR__)

    {:ok, feishu_manifest} = Esr.Plugin.Manifest.parse(feishu_manifest_path)
    {:ok, cc_manifest} = Esr.Plugin.Manifest.parse(cc_manifest_path)

    for entry <- feishu_manifest.channels do
      Esr.Channel.Registry.register("feishu", entry.name, entry.module, %{
        config_schema: entry.config_schema,
        pipeline_contributions: entry.pipeline_contributions,
        proxies: entry.proxies
      })
    end

    for entry <- cc_manifest.channels do
      Esr.Channel.Registry.register("claude_code", entry.name, entry.module, %{
        config_schema: entry.config_schema,
        pipeline_contributions: entry.pipeline_contributions,
        proxies: entry.proxies
      })
    end

    for entry <- cc_manifest.agent_kinds do
      Esr.Plugin.AgentKindRegistry.register(
        "claude_code",
        entry.name,
        Map.put(entry, :plugin, "claude_code")
      )
    end

    on_exit(fn ->
      Esr.Channel.Registry.clear()
      Esr.Plugin.AgentKindRegistry.clear()
    end)

    :ok
  end

  test "INVARIANT: feishu-cc agent_def.capabilities_required is byte-identical to pre-Phase-6 baseline" do
    runtime = %{
      chat_id: "oc_invariant",
      app_id: "esr_dev_helper",
      principal_id: "ou_alice",
      name: "alice"
    }

    assert {:ok, agent_def} = AgentDefBuilder.build(feishu_cc_template(), runtime)

    # `==` (not `MapSet.new` etc) — byte-identical, ordered list
    # comparison. If Phase 6 silently reordered or dropped a cap, this
    # fires.
    assert agent_def.capabilities_required == @baseline_caps,
           """
           Phase 6 cap-source migration changed the resolved cap set.

           Expected (pre-Phase-6 agents.yaml fixture):
             #{inspect(@baseline_caps, pretty: true)}

           Got (post-Phase-6 plugin manifest registry):
             #{inspect(agent_def.capabilities_required, pretty: true)}

           If this drift is intentional:
             1. Update @baseline_caps in this test
             2. Update runtime/lib/esr/plugins/claude_code/manifest.yaml's
                agent_kinds[0].capabilities_required to match
             3. Update runtime/test/esr/fixtures/agents/simple.yaml
                (kept as fixture-only data after Phase 6)
           in lockstep.
           """
  end

  test "INVARIANT: agent_def.pipeline.inbound names match pre-Phase-6 simple.yaml shape" do
    # Sister invariant: the canonical CC chain shape is preserved.
    # Phase 5 hardcoded these names in AgentDefBuilder; Phase 6 sources
    # them from the plugin manifest. The wire-shape (which peer names
    # appear, in what order) must be byte-identical so downstream
    # ActorQuery / lookup_by_chat_thread routing keys still resolve.
    expected_inbound_names = [
      "feishu_chat_proxy",
      "cc_proxy",
      "cc_process",
      "pty_process"
    ]

    runtime = %{
      chat_id: "oc_invariant",
      app_id: "esr_dev_helper",
      principal_id: "ou_alice",
      name: "alice"
    }

    assert {:ok, agent_def} = AgentDefBuilder.build(feishu_cc_template(), runtime)

    inbound_names = Enum.map(agent_def.pipeline.inbound, & &1["name"])

    assert inbound_names == expected_inbound_names
  end

  test "INVARIANT: feishu_app_proxy with intact ${app_id} placeholder" do
    # The `${app_id}` literal must survive intact through manifest
    # parsing + builder composition. AgentSpawner.build_ctx/2
    # substitutes it at spawn time using `params[:app_id]`; doing it
    # earlier (during materialization) would freeze the wrong app_id
    # when different sessions reuse the same template.
    runtime = %{chat_id: "oc_invariant", app_id: "ignored", principal_id: "x", name: "alice"}

    assert {:ok, agent_def} = AgentDefBuilder.build(feishu_cc_template(), runtime)

    [proxy] = agent_def.proxies
    assert proxy["name"] == "feishu_app_proxy"
    assert proxy["impl"] == "Esr.Entity.FeishuAppProxy"
    assert proxy["target"] == "admin::feishu_app_adapter_${app_id}"
  end
end
