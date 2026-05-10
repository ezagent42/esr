defmodule Esr.SessionTemplate.AgentDefBuilderTest do
  @moduledoc """
  Tests for `Esr.SessionTemplate.AgentDefBuilder` — the Phase 5 hook
  that materializes a `SessionTemplate` into the `agent_def`-shaped map
  consumed by `Esr.Session.AgentSpawner`.

  Spec: `docs/superpowers/specs/2026-05-10-session-template-and-channel.md`
  §5.4. Plan Phase 5 Task 5.2.
  """
  use ExUnit.Case, async: true

  alias Esr.SessionTemplate
  alias Esr.SessionTemplate.AgentDefBuilder

  defp feishu_cc_template do
    %SessionTemplate{
      schema_version: 1,
      name: "feishu-cc",
      description: "Feishu chat → Claude Code agent",
      dependencies: %{plugins: ["feishu", "claude_code"], bundles: []},
      channels: [
        %{alias: "in", kind: "feishu.chat_proxy", config: %{"app_id" => "<runtime>", "chat_id" => "<runtime>"}},
        %{alias: "cc_mcp", kind: "claude_code.mcp_http", config: %{"port" => "ephemeral"}}
      ],
      agents: [
        %{kind: "claude_code.cc", name: "<runtime>", consumes: ["cc_mcp"]}
      ],
      flow: %{
        inbound: [%{source: "in.text", pipeline: [{:unresolved, "Esr.Entity.Agent.MentionParser"}]}],
        outbound: [%{source: "<agent>.reply", sink: "in.send"}]
      }
    }
  end

  describe "build/2 — happy path" do
    test "feishu-cc topology yields the canonical CC inbound chain" do
      runtime = %{chat_id: "oc_X", app_id: "esr_dev_helper", principal_id: "ou_alice", name: "alice"}

      assert {:ok, agent_def} = AgentDefBuilder.build(feishu_cc_template(), runtime)

      assert agent_def.description == "Feishu chat → Claude Code agent"

      # Inbound order locks the existing simple.yaml fixture: feishu_chat_proxy
      # comes from the `feishu.chat_proxy` channel, the cc trio comes from
      # `claude_code.cc` agent kind.
      inbound_names = Enum.map(agent_def.pipeline.inbound, & &1["name"])

      assert inbound_names == [
               "feishu_chat_proxy",
               "cc_proxy",
               "cc_process",
               "pty_process"
             ]

      inbound_impls = Enum.map(agent_def.pipeline.inbound, & &1["impl"])

      assert inbound_impls == [
               "Esr.Plugins.Feishu.FeishuChatProxy",
               "Esr.Entity.CCProxy",
               "Esr.Entity.CCProcess",
               "Esr.Entity.PtyProcess"
             ]
    end

    test "outbound order is the inbound chain reversed (matches simple.yaml)" do
      runtime = %{chat_id: "oc_X", app_id: "default", principal_id: "ou_alice", name: "alice"}

      assert {:ok, agent_def} = AgentDefBuilder.build(feishu_cc_template(), runtime)

      assert agent_def.pipeline.outbound == [
               "pty_process",
               "cc_process",
               "cc_proxy",
               "feishu_chat_proxy"
             ]
    end

    test "channel_proxies block carries FeishuAppProxy with intact ${app_id} placeholder" do
      # The placeholder is intentionally left for AgentSpawner.build_ctx to
      # substitute — different sessions sharing the same materialized
      # template each carry their own app_id.
      runtime = %{chat_id: "oc_X", app_id: "e2e-mock", principal_id: "ou_alice", name: "alice"}

      assert {:ok, agent_def} = AgentDefBuilder.build(feishu_cc_template(), runtime)

      [proxy] = agent_def.proxies
      assert proxy["name"] == "feishu_app_proxy"
      assert proxy["impl"] == "Esr.Entity.FeishuAppProxy"
      assert proxy["target"] == "admin::feishu_app_adapter_${app_id}"
    end

    test "capabilities_required matches today's cc fixture verbatim" do
      runtime = %{chat_id: "oc_X", app_id: "default", principal_id: "ou_alice", name: "alice"}

      assert {:ok, agent_def} = AgentDefBuilder.build(feishu_cc_template(), runtime)

      assert "session:default/create" in agent_def.capabilities_required
      assert "pty:default/spawn" in agent_def.capabilities_required
      assert "handler:cc_adapter_runner/invoke" in agent_def.capabilities_required
    end
  end

  describe "build/2 — runtime_params substitution tolerance" do
    test "missing chat_id/app_id is acceptable: AgentSpawner reads from params at spawn time" do
      # AgentSpawner.build_ctx/2 reads chat_id/app_id from params, not from
      # the materialized agent_def. So the builder doesn't have to fail
      # when those keys are absent — the substitution surface is the
      # FeishuAppProxy `target` string's `${app_id}`, which is processed
      # by AgentSpawner at spawn time.
      assert {:ok, _agent_def} = AgentDefBuilder.build(feishu_cc_template(), %{})
    end
  end

  describe "build/2 — error paths" do
    test "unsupported channel kind → {:error, {:unsupported_channel_kind, kind}}" do
      bad =
        feishu_cc_template()
        |> Map.put(:channels, [
          %{alias: "x", kind: "voice.unknown_transport", config: %{}}
        ])

      assert {:error, {:unsupported_channel_kind, "voice.unknown_transport"}} =
               AgentDefBuilder.build(bad, %{})
    end

    test "unsupported agent kind → {:error, {:unsupported_agent_kind, kind}}" do
      bad =
        feishu_cc_template()
        |> Map.put(:agents, [%{kind: "codex.cli", name: "x", consumes: []}])

      assert {:error, {:unsupported_agent_kind, "codex.cli"}} =
               AgentDefBuilder.build(bad, %{})
    end

    test "no agents declared → {:error, {:no_agents, template_name}}" do
      bad = Map.put(feishu_cc_template(), :agents, [])

      assert {:error, {:no_agents, "feishu-cc"}} = AgentDefBuilder.build(bad, %{})
    end
  end
end
