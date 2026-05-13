defmodule Esr.SessionTemplate.ParserTest do
  @moduledoc """
  Tests for `Esr.SessionTemplate.Parser`.

  Spec: `docs/superpowers/specs/2026-05-10-session-template-and-channel.md`
  §5.3. Phase 4 (Task 4.2).
  """
  use ExUnit.Case, async: false

  alias Esr.SessionTemplate
  alias Esr.SessionTemplate.Parser
  alias Esr.SessionTemplate.FlowNodeRegistry

  setup do
    # FlowNodeRegistry seeds itself at init/1; the verify_flow_nodes:
    # tests below need it live.
    case start_supervised(FlowNodeRegistry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> FlowNodeRegistry.clear()
    end

    case start_supervised(Esr.Channel.Registry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> Esr.Channel.Registry.clear()
    end

    on_exit(fn ->
      FlowNodeRegistry.clear()
      Esr.Channel.Registry.clear()
    end)

    :ok
  end

  defp valid_yaml do
    """
    schema_version: 1
    name: feishu-cc
    description: Feishu chat → CC
    channels:
      - alias: in
        kind: feishu.chat_proxy
        config:
          app_id: <runtime>
          chat_id: <runtime>
      - alias: cc_mcp
        kind: claude_code.mcp_stdio
        config:
          port: ephemeral
    agents:
      - kind: claude_code.cc
        name: <runtime>
        consumes: [cc_mcp]
    flow:
      inbound:
        - source: in.text
          pipeline:
            - Esr.Entity.Agent.MentionParser
            - "<route_to_agent>"
      outbound:
        - source: <agent>.reply
          sink: in.send
    """
  end

  describe "happy path" do
    test "parses the canonical feishu-cc template" do
      assert {:ok, %SessionTemplate{} = t} = Parser.parse(valid_yaml())
      assert t.schema_version == 1
      assert t.name == "feishu-cc"
      assert t.description == "Feishu chat → CC"
      assert length(t.channels) == 2
      assert Enum.map(t.channels, & &1.alias) == ["in", "cc_mcp"]
      assert Enum.map(t.channels, & &1.kind) == ["feishu.chat_proxy", "claude_code.mcp_stdio"]
      assert length(t.agents) == 1
      assert hd(t.agents) == %{kind: "claude_code.cc", name: "<runtime>", consumes: ["cc_mcp"]}
      assert length(t.flow.inbound) == 1
      assert length(t.flow.outbound) == 1
    end

    test "absent dependencies block defaults to empty lists" do
      assert {:ok, t} = Parser.parse(valid_yaml())
      assert t.dependencies == %{plugins: [], bundles: []}
    end

    test "explicit dependencies via opts wins over yaml body" do
      yaml = """
      schema_version: 1
      dependencies:
        plugins: [old]
      channels: []
      agents: []
      flow: {}
      """

      assert {:ok, t} =
               Parser.parse(yaml, dependencies: %{plugins: ["new"], bundles: []})

      assert t.dependencies == %{plugins: ["new"], bundles: []}
    end

    test "operator-shipped form (dependencies inline) preserved" do
      yaml = """
      schema_version: 1
      name: my-custom
      dependencies:
        plugins: [feishu]
        bundles: []
      channels: []
      agents: []
      flow: {}
      """

      assert {:ok, t} = Parser.parse(yaml)
      assert t.dependencies == %{plugins: ["feishu"], bundles: []}
    end

    test "pipeline entries are unresolved by default (no verify)" do
      assert {:ok, t} = Parser.parse(valid_yaml())
      [first_inbound] = t.flow.inbound

      assert first_inbound.pipeline == [
               {:unresolved, "Esr.Entity.Agent.MentionParser"},
               {:unresolved, "<route_to_agent>"}
             ]
    end

    test "pipeline entries resolve when verify_flow_nodes: true" do
      assert {:ok, t} = Parser.parse(valid_yaml(), verify_flow_nodes: true)
      [first_inbound] = t.flow.inbound

      assert first_inbound.pipeline == [
               {:module, Esr.Entity.Agent.MentionParser},
               {:builtin, :builtin_route_to_agent}
             ]
    end
  end

  describe "schema_version" do
    test "missing schema_version" do
      yaml = "name: x\nchannels: []\n"
      assert {:error, {:missing_field, "schema_version"}} = Parser.parse(yaml)
    end

    test "schema_version != 1" do
      yaml = "schema_version: 2\nchannels: []\n"
      assert {:error, {:schema_version_mismatch, expected: 1, got: 2}} = Parser.parse(yaml)
    end
  end

  describe "channels validation" do
    test "duplicate aliases rejected" do
      yaml = """
      schema_version: 1
      channels:
        - alias: in
          kind: feishu.chat_proxy
        - alias: in
          kind: claude_code.mcp_stdio
      agents: []
      flow: {}
      """

      assert {:error, {:duplicate_channel_alias, "in"}} = Parser.parse(yaml)
    end

    test "missing alias" do
      yaml = """
      schema_version: 1
      channels:
        - kind: feishu.chat_proxy
      agents: []
      flow: {}
      """

      assert {:error, {:channel_missing_field, "alias"}} = Parser.parse(yaml)
    end

    test "missing kind" do
      yaml = """
      schema_version: 1
      channels:
        - alias: in
      agents: []
      flow: {}
      """

      assert {:error, {:channel_missing_field, "kind"}} = Parser.parse(yaml)
    end

    test "malformed kind (no dot)" do
      yaml = """
      schema_version: 1
      channels:
        - alias: in
          kind: feishu_chat_proxy
      agents: []
      flow: {}
      """

      assert {:error, {:channel_kind_malformed, "feishu_chat_proxy"}} = Parser.parse(yaml)
    end

    test "verify_channels: true rejects unknown kinds" do
      yaml = """
      schema_version: 1
      channels:
        - alias: ghost
          kind: unknown.transport
      agents: []
      flow: {}
      """

      assert {:error, {:unknown_channel_kind, "unknown.transport", alias: "ghost"}} =
               Parser.parse(yaml, verify_channels: true)
    end

    test "verify_channels: true accepts registered kinds" do
      defmodule SomeChannel, do: false
      Esr.Channel.Registry.register("test_plugin", "demo", SomeChannel)

      yaml = """
      schema_version: 1
      channels:
        - alias: t
          kind: test_plugin.demo
      agents: []
      flow: {}
      """

      assert {:ok, _t} = Parser.parse(yaml, verify_channels: true)
    end
  end

  describe "agents validation" do
    test "missing kind" do
      yaml = """
      schema_version: 1
      channels: []
      agents:
        - name: foo
      flow: {}
      """

      assert {:error, {:agent_missing_field, "kind"}} = Parser.parse(yaml)
    end

    test "malformed kind" do
      yaml = """
      schema_version: 1
      channels: []
      agents:
        - kind: cc
          name: foo
      flow: {}
      """

      assert {:error, {:agent_kind_malformed, "cc"}} = Parser.parse(yaml)
    end

    test "consumes references unknown alias" do
      yaml = """
      schema_version: 1
      channels:
        - alias: real
          kind: claude_code.mcp_stdio
      agents:
        - kind: claude_code.cc
          name: a
          consumes: [ghost]
      flow: {}
      """

      assert {:error, {:consumes_unknown_alias, "ghost"}} = Parser.parse(yaml)
    end
  end

  describe "flow.inbound validation" do
    test "source references unknown alias" do
      yaml = """
      schema_version: 1
      channels:
        - alias: in
          kind: feishu.chat_proxy
      agents: []
      flow:
        inbound:
          - source: ghost.text
            pipeline: []
        outbound: []
      """

      assert {:error, {:inbound_source_unknown_alias, "ghost.text"}} = Parser.parse(yaml)
    end

    test "source missing event suffix" do
      yaml = """
      schema_version: 1
      channels:
        - alias: in
          kind: feishu.chat_proxy
      agents: []
      flow:
        inbound:
          - source: in
            pipeline: []
        outbound: []
      """

      assert {:error, {:inbound_source_unknown_alias, "in"}} = Parser.parse(yaml)
    end

    test "verify_flow_nodes: true rejects unknown pipeline entry" do
      yaml = """
      schema_version: 1
      channels:
        - alias: in
          kind: feishu.chat_proxy
      agents: []
      flow:
        inbound:
          - source: in.text
            pipeline:
              - "<bogus_router>"
        outbound: []
      """

      assert {:error, {:unknown_flow_node, "<bogus_router>"}} =
               Parser.parse(yaml, verify_flow_nodes: true)
    end

    test "pipeline entry is malformed (lowercase module)" do
      yaml = """
      schema_version: 1
      channels:
        - alias: in
          kind: feishu.chat_proxy
      agents: []
      flow:
        inbound:
          - source: in.text
            pipeline:
              - lowercase_string
        outbound: []
      """

      assert {:error, {:invalid_pipeline_entry, "lowercase_string"}} = Parser.parse(yaml)
    end
  end

  describe "flow.outbound validation" do
    test "sink references unknown alias" do
      yaml = """
      schema_version: 1
      channels:
        - alias: in
          kind: feishu.chat_proxy
      agents: []
      flow:
        inbound: []
        outbound:
          - source: <agent>.reply
            sink: ghost.send
      """

      assert {:error, {:outbound_sink_unknown_alias, "ghost.send"}} = Parser.parse(yaml)
    end

    test "sink missing action suffix" do
      yaml = """
      schema_version: 1
      channels:
        - alias: in
          kind: feishu.chat_proxy
      agents: []
      flow:
        inbound: []
        outbound:
          - source: <agent>.reply
            sink: in
      """

      assert {:error, {:outbound_sink_unknown_alias, "in"}} = Parser.parse(yaml)
    end
  end

  describe "yaml-level errors" do
    test "non-map yaml" do
      assert {:error, :not_a_map} = Parser.parse("- 1\n- 2\n")
    end

    test "malformed yaml" do
      assert {:error, _} = Parser.parse("schema_version: 1\nname: x\n  bad: indent\n")
    end
  end
end
