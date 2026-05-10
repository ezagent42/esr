defmodule Esr.Bundles.FeishuCcTest do
  @moduledoc """
  Smoke test for the in-tree feishu-cc bundle.

  Spec: `docs/superpowers/specs/2026-05-10-session-template-and-channel.md`
  §5.3 + §5.4 (default template). Phase 4 (Task 4.4).

  Loads `runtime/lib/esr/bundles/feishu-cc/` via `Bundle.Loader.load_all/1`
  with feishu + claude_code in the enabled list, asserts the template
  registers + has the expected shape.
  """
  use ExUnit.Case, async: false

  alias Esr.Bundle
  alias Esr.SessionTemplate

  setup do
    case start_supervised(Bundle.Registry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> Bundle.Registry.clear()
    end

    case start_supervised(SessionTemplate.Registry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> SessionTemplate.Registry.clear()
    end

    on_exit(fn ->
      Bundle.Registry.clear()
      SessionTemplate.Registry.clear()
    end)

    :ok
  end

  test "in-tree feishu-cc bundle parses + registers cleanly" do
    bundles_dir = Path.expand("../../../lib/esr/bundles", __DIR__)
    assert File.dir?(bundles_dir), "expected bundles dir at #{bundles_dir}"
    assert File.regular?(Path.join([bundles_dir, "feishu-cc", "manifest.yaml"]))
    assert File.regular?(Path.join([bundles_dir, "feishu-cc", "template.yaml"]))

    :ok = Bundle.Loader.load_all(
      bundles_dir: bundles_dir,
      session_templates_dir: "/nonexistent_for_test",
      enabled_plugins: ["feishu", "claude_code"]
    )

    # Bundle metadata.
    assert {:ok, %{manifest: manifest}} = Bundle.Registry.lookup("feishu-cc")
    assert manifest.name == "feishu-cc"
    assert manifest.dependencies.plugins == ["feishu", "claude_code"]

    # Template body.
    assert {:ok, %SessionTemplate{} = template} = SessionTemplate.Registry.lookup("feishu-cc")
    assert template.schema_version == 1
    assert template.name == "feishu-cc"

    # Channels: in (feishu.chat_proxy) + cc_mcp (claude_code.mcp_http).
    assert length(template.channels) == 2
    aliases = Enum.map(template.channels, & &1.alias)
    assert "in" in aliases
    assert "cc_mcp" in aliases

    in_channel = Enum.find(template.channels, &(&1.alias == "in"))
    assert in_channel.kind == "feishu.chat_proxy"
    assert in_channel.config["app_id"] == "<runtime>"
    assert in_channel.config["chat_id"] == "<runtime>"

    cc_channel = Enum.find(template.channels, &(&1.alias == "cc_mcp"))
    assert cc_channel.kind == "claude_code.mcp_http"

    # Single agent: cc, consumes cc_mcp.
    assert length(template.agents) == 1
    [agent] = template.agents
    assert agent.kind == "claude_code.cc"
    assert agent.consumes == ["cc_mcp"]

    # Flow: one inbound (in.text → MentionParser → <route_to_agent>),
    # one outbound (<agent>.reply → in.send).
    assert length(template.flow.inbound) == 1
    [inbound] = template.flow.inbound
    assert inbound.source == "in.text"
    assert length(inbound.pipeline) == 2

    assert length(template.flow.outbound) == 1
    [outbound] = template.flow.outbound
    assert outbound.source == "<agent>.reply"
    assert outbound.sink == "in.send"
  end

  test "feishu-cc skips template registration when claude_code missing" do
    bundles_dir = Path.expand("../../../lib/esr/bundles", __DIR__)

    :ok = Bundle.Loader.load_all(
      bundles_dir: bundles_dir,
      session_templates_dir: "/nonexistent_for_test",
      enabled_plugins: ["feishu"]
    )

    assert {:ok, _} = Bundle.Registry.lookup("feishu-cc")
    assert :not_found = SessionTemplate.Registry.lookup("feishu-cc")
  end
end
