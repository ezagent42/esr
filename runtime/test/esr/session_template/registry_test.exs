defmodule Esr.SessionTemplate.RegistryTest do
  @moduledoc """
  Tests for `Esr.SessionTemplate.Registry`.

  Spec: `docs/superpowers/specs/2026-05-10-session-template-and-channel.md`
  §5.3, §5.5. Phase 4 (Task 4.3).

  `async: false` because the Registry owns a named ETS table; concurrent
  tests would race on `clear/0`.
  """
  use ExUnit.Case, async: false

  alias Esr.SessionTemplate.Registry

  setup do
    case start_supervised(Registry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> Registry.clear()
    end

    # Phase 6 (2026-05-10): materialize/2 reads channel +
    # agent_kind contributions from the plugin registries. The
    # `materialize/2` describe-block below references `feishu.chat_proxy`,
    # `claude_code.mcp_http`, and `claude_code.cc` — register them here
    # so the builder finds them. Stub modules `Esr.Entity.Server` /
    # `Esr.Entity.PtyProcess` are core-shipped + always loaded.
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

    Esr.Channel.Registry.register("feishu", "chat_proxy", Esr.Entity.Server, %{
      pipeline_contributions: [
        %{"name" => "feishu_chat_proxy", "impl" => "Esr.Plugins.Feishu.FeishuChatProxy"}
      ],
      proxies: [
        %{
          "name" => "feishu_app_proxy",
          "impl" => "Esr.Entity.FeishuAppProxy",
          "target" => "admin::feishu_app_adapter_${app_id}"
        }
      ]
    })

    Esr.Channel.Registry.register("claude_code", "mcp_http", Esr.Entity.PtyProcess, %{
      pipeline_contributions: [],
      proxies: []
    })

    Esr.Plugin.AgentKindRegistry.register("claude_code", "cc", %{
      plugin: "claude_code",
      name: "cc",
      description: "Claude Code",
      handler_module: "cc_adapter_runner",
      pipeline: %{
        inbound: [
          %{"name" => "cc_proxy", "impl" => "Esr.Entity.CCProxy"},
          %{"name" => "cc_process", "impl" => "Esr.Entity.CCProcess"},
          %{"name" => "pty_process", "impl" => "Esr.Entity.PtyProcess"}
        ],
        outbound: ["pty_process", "cc_process", "cc_proxy"]
      },
      proxies: [],
      capabilities_required: [
        "session:default/create",
        "pty:default/spawn",
        "handler:cc_adapter_runner/invoke"
      ],
      params: []
    })

    on_exit(fn ->
      Registry.clear()
      Esr.Channel.Registry.clear()
      Esr.Plugin.AgentKindRegistry.clear()
    end)

    :ok
  end

  defp template(name) do
    %Esr.SessionTemplate{
      schema_version: 1,
      name: name,
      description: "",
      dependencies: %{plugins: [], bundles: []},
      channels: [],
      agents: [],
      flow: %{inbound: [], outbound: []}
    }
  end

  test "register/3 + lookup/1 round-trips a bundle template" do
    t = template("feishu-cc")
    :ok = Registry.register("feishu-cc", t, source: {:bundle, "feishu-cc"})
    assert {:ok, ^t} = Registry.lookup("feishu-cc")
  end

  test "register/3 + lookup/1 round-trips an operator template" do
    t = template("custom")
    :ok = Registry.register("custom", t, source: :operator)
    assert {:ok, ^t} = Registry.lookup("custom")
  end

  test "register/3 missing source: raises" do
    t = template("x")
    assert_raise KeyError, fn -> Registry.register("x", t, []) end
  end

  test "lookup/1 unknown returns :not_found" do
    assert :not_found = Registry.lookup("ghost")
  end

  test "list_all/0 returns every name + source" do
    Registry.register("a", template("a"), source: {:bundle, "a"})
    Registry.register("b", template("b"), source: :operator)

    pairs = Registry.list_all()
    by_name = Enum.into(pairs, %{}, fn %{name: n, source: s} -> {n, s} end)
    assert by_name["a"] == {:bundle, "a"}
    assert by_name["b"] == :operator
  end

  test "register/3 same name overwrites (operator override of bundle)" do
    Registry.register("foo", template("foo-bundle"), source: {:bundle, "foo"})
    Registry.register("foo", template("foo-operator"), source: :operator)
    assert {:ok, %{name: "foo-operator"}} = Registry.lookup("foo")

    [%{name: "foo", source: source}] = Registry.list_all()
    assert source == :operator
  end

  test "unregister/1 removes" do
    Registry.register("foo", template("foo"), source: :operator)
    Registry.unregister("foo")
    assert :not_found = Registry.lookup("foo")
  end

  describe "materialize/2 (Phase 5)" do
    defp feishu_cc_full_template(name) do
      %Esr.SessionTemplate{
        schema_version: 1,
        name: name,
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
          inbound: [%{source: "in.text", pipeline: []}],
          outbound: [%{source: "<agent>.reply", sink: "in.send"}]
        }
      }
    end

    test "happy path: registered template + runtime params yields agent_def" do
      Registry.register("feishu-cc", feishu_cc_full_template("feishu-cc"),
        source: {:bundle, "feishu-cc"}
      )

      assert {:ok, agent_def} =
               Registry.materialize("feishu-cc", %{
                 chat_id: "oc_X",
                 app_id: "esr_dev_helper",
                 principal_id: "ou_alice",
                 name: "alice"
               })

      assert is_map(agent_def)
      assert is_list(agent_def.pipeline.inbound)
      assert agent_def.capabilities_required != []
    end

    test "missing template → {:error, :template_not_found}" do
      assert {:error, :template_not_found} = Registry.materialize("ghost", %{})
    end

    test "registered template with unsupported channel kind → builder error surfaces" do
      bad = %{
        feishu_cc_full_template("bad") |
        channels: [%{alias: "x", kind: "voice.transport", config: %{}}]
      }

      Registry.register("bad", bad, source: :operator)

      assert {:error, {:unsupported_channel_kind, "voice.transport"}} =
               Registry.materialize("bad", %{})
    end
  end
end
