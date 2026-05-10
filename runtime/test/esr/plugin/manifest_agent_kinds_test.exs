defmodule Esr.Plugin.ManifestAgentKindsTest do
  @moduledoc """
  Tests for the `agent_kinds:` block on `Esr.Plugin.Manifest`.

  Spec: `docs/superpowers/specs/2026-05-10-session-template-and-channel.md`,
  Phase 6.

  Top-level (sibling of `name:`/`version:`) yaml block; lifted onto the
  struct as `manifest.agent_kinds` (a list of maps with `:name`,
  `:description`, `:handler_module`, `:pipeline` (with `:inbound` /
  `:outbound`), `:proxies`, `:capabilities_required`, `:params`).

  Validation rules (parse-time):
    * each entry has a non-empty string `name`
    * `pipeline.inbound` is a non-empty list of maps, each with string
      `name` + `impl`
    * `pipeline.outbound` defaults to the reverse of inbound's `name`
      projection when omitted
    * malformed shape → `{:error, {:invalid_agent_kind, reason}}`
  """
  use ExUnit.Case, async: true

  alias Esr.Plugin.Manifest

  test "parse with full agent_kinds: block populates manifest.agent_kinds" do
    yaml = ~S"""
    name: test-plugin
    version: 0.1.0
    agent_kinds:
      - name: cc
        description: "Claude Code"
        handler_module: cc_adapter_runner
        capabilities_required:
          - session:default/create
          - handler:cc_adapter_runner/invoke
        pipeline:
          inbound:
            - { name: cc_proxy,    impl: Esr.Entity.CCProxy }
            - { name: cc_process,  impl: Esr.Entity.CCProcess }
            - { name: pty_process, impl: Esr.Entity.PtyProcess }
          outbound:
            - pty_process
            - cc_process
            - cc_proxy
        params:
          - { name: dir, required: true, type: path }
    """

    {:ok, manifest} = Manifest.parse_string(yaml)

    assert length(manifest.agent_kinds) == 1
    [cc] = manifest.agent_kinds
    assert cc.name == "cc"
    assert cc.description == "Claude Code"
    assert cc.handler_module == "cc_adapter_runner"
    assert cc.capabilities_required == ["session:default/create", "handler:cc_adapter_runner/invoke"]
    assert length(cc.pipeline.inbound) == 3
    # Inbound entries are normalized to string-keyed maps so the
    # AgentSpawner walker (which reads spec["name"] / spec["impl"])
    # finds them regardless of yaml key style.
    assert Enum.all?(cc.pipeline.inbound, fn e ->
             is_binary(e["name"]) and is_binary(e["impl"])
           end)

    assert cc.pipeline.outbound == ["pty_process", "cc_process", "cc_proxy"]
    assert length(cc.params) == 1
  end

  test "parse defaults pipeline.outbound to reverse of inbound names when omitted" do
    yaml = ~S"""
    name: test-plugin
    version: 0.1.0
    agent_kinds:
      - name: cc
        pipeline:
          inbound:
            - { name: cc_proxy,    impl: Esr.Entity.CCProxy }
            - { name: cc_process,  impl: Esr.Entity.CCProcess }
            - { name: pty_process, impl: Esr.Entity.PtyProcess }
    """

    {:ok, manifest} = Manifest.parse_string(yaml)
    [cc] = manifest.agent_kinds
    assert cc.pipeline.outbound == ["pty_process", "cc_process", "cc_proxy"]
    # Optional fields default to sensible empty values.
    assert cc.description == ""
    assert cc.handler_module == nil
    assert cc.capabilities_required == []
    assert cc.proxies == []
    assert cc.params == []
  end

  test "parse with no agent_kinds: block leaves manifest.agent_kinds empty" do
    yaml = ~S"""
    name: test-plugin
    version: 0.1.0
    """

    {:ok, manifest} = Manifest.parse_string(yaml)
    assert manifest.agent_kinds == []
  end

  test "agent_kind entry missing :name returns invalid_agent_kind error" do
    yaml = ~S"""
    name: test-plugin
    version: 0.1.0
    agent_kinds:
      - description: "no name"
        pipeline:
          inbound:
            - { name: foo, impl: Esr.Entity.PtyProcess }
    """

    assert {:error, {:invalid_agent_kind, {:missing_field, "name"}}} =
             Manifest.parse_string(yaml)
  end

  test "agent_kind missing pipeline.inbound returns invalid_pipeline error" do
    yaml = ~S"""
    name: test-plugin
    version: 0.1.0
    agent_kinds:
      - name: cc
        pipeline: {}
    """

    assert {:error, {:invalid_agent_kind, {:invalid_pipeline, :empty_inbound}}} =
             Manifest.parse_string(yaml)
  end

  test "agent_kind with non-list inbound returns error" do
    yaml = ~S"""
    name: test-plugin
    version: 0.1.0
    agent_kinds:
      - name: cc
        pipeline:
          inbound: "not a list"
    """

    assert {:error, {:invalid_agent_kind, {:invalid_pipeline, :inbound_not_a_list}}} =
             Manifest.parse_string(yaml)
  end

  test "agent_kind inbound entry missing :name returns error" do
    yaml = ~S"""
    name: test-plugin
    version: 0.1.0
    agent_kinds:
      - name: cc
        pipeline:
          inbound:
            - { impl: Esr.Entity.PtyProcess }
    """

    assert {:error, {:invalid_agent_kind, {:invalid_pipeline, :inbound_entry_missing_name_or_impl}}} =
             Manifest.parse_string(yaml)
  end

  test "agent_kinds: not a list returns error" do
    yaml = ~S"""
    name: test-plugin
    version: 0.1.0
    agent_kinds:
      foo: bar
    """

    assert {:error, {:invalid_agent_kind, {:not_a_list, _}}} = Manifest.parse_string(yaml)
  end

  test "claude_code's real manifest declares cc agent_kind" do
    # Smoke test: the in-tree manifest parses cleanly and the cc
    # agent_kind is shaped how AgentSpawner consumes it.
    path = Path.expand("../../../lib/esr/plugins/claude_code/manifest.yaml", __DIR__)
    {:ok, manifest} = Manifest.parse(path)

    [cc] = manifest.agent_kinds
    assert cc.name == "cc"
    assert cc.handler_module == "cc_adapter_runner"
    # Three inbound peers — cc_proxy, cc_process, pty_process — match
    # today's `cc` agent fixture chain (without the channel-contributed
    # feishu_chat_proxy + feishu_app_proxy, which come from the
    # template's channels: block).
    assert Enum.map(cc.pipeline.inbound, & &1["name"]) ==
             ["cc_proxy", "cc_process", "pty_process"]
  end
end
