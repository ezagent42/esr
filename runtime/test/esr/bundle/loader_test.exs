defmodule Esr.Bundle.LoaderTest do
  @moduledoc """
  Tests for `Esr.Bundle.Loader`.

  Spec: `docs/superpowers/specs/2026-05-10-session-template-and-channel.md`
  §5.3, §5.5. Phase 4 (Task 4.3).

  `async: false` because the Loader writes into named-ETS-backed
  registries (`Esr.Bundle.Registry`, `Esr.SessionTemplate.Registry`).
  """
  use ExUnit.Case, async: false

  alias Esr.Bundle
  alias Esr.SessionTemplate

  @tmp_dir Path.join(System.tmp_dir!(), "esr_bundle_loader_test")

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)

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
      File.rm_rf!(@tmp_dir)
    end)

    :ok
  end

  defp write_bundle!(name, manifest_yaml, template_yaml) do
    dir = Path.join(@tmp_dir, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "manifest.yaml"), manifest_yaml)
    File.write!(Path.join(dir, "template.yaml"), template_yaml)
    dir
  end

  defp manifest_yaml(opts \\ []) do
    name = Keyword.get(opts, :name, "feishu-cc")
    plugins = Keyword.get(opts, :plugins, ["feishu", "claude_code"])
    plugins_yaml = "[" <> Enum.map_join(plugins, ", ", & &1) <> "]"

    """
    schema_version: 1
    name: #{name}
    version: 0.1.0
    description: Test bundle
    dependencies:
      plugins: #{plugins_yaml}
      bundles: []
    """
  end

  defp template_yaml(opts \\ []) do
    name = Keyword.get(opts, :name, "feishu-cc")

    """
    schema_version: 1
    name: #{name}
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

  describe "load_all/1 — bundles dir" do
    test "happy path: registers manifest + template" do
      write_bundle!("feishu-cc", manifest_yaml(), template_yaml())

      :ok = Bundle.Loader.load_all(
        bundles_dir: @tmp_dir,
        session_templates_dir: "/nonexistent",
        enabled_plugins: ["feishu", "claude_code"]
      )

      assert {:ok, %{manifest: m, source_path: path}} = Bundle.Registry.lookup("feishu-cc")
      assert m.name == "feishu-cc"
      assert path == Path.join(@tmp_dir, "feishu-cc")

      assert {:ok, %SessionTemplate{name: "feishu-cc"}} =
               SessionTemplate.Registry.lookup("feishu-cc")

      [attribution] = SessionTemplate.Registry.list_all()
      assert attribution.source == {:bundle, "feishu-cc"}
    end

    test "missing plugin dep: manifest registered, template skipped" do
      write_bundle!("feishu-cc", manifest_yaml(), template_yaml())

      :ok = Bundle.Loader.load_all(
        bundles_dir: @tmp_dir,
        session_templates_dir: "/nonexistent",
        enabled_plugins: ["feishu"]
      )

      assert {:ok, _} = Bundle.Registry.lookup("feishu-cc")
      assert :not_found = SessionTemplate.Registry.lookup("feishu-cc")
    end

    test "malformed manifest: skipped + logged" do
      dir = Path.join(@tmp_dir, "broken")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "manifest.yaml"), "not_a_valid: schema_version_value\n")
      File.write!(Path.join(dir, "template.yaml"), template_yaml())

      :ok = Bundle.Loader.load_all(
        bundles_dir: @tmp_dir,
        session_templates_dir: "/nonexistent",
        enabled_plugins: ["feishu", "claude_code"]
      )

      assert :not_found = Bundle.Registry.lookup("broken")
      assert :not_found = SessionTemplate.Registry.lookup("broken")
    end

    test "missing template.yaml: skipped" do
      dir = Path.join(@tmp_dir, "no_template")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "manifest.yaml"), manifest_yaml(name: "no_template"))

      :ok = Bundle.Loader.load_all(
        bundles_dir: @tmp_dir,
        session_templates_dir: "/nonexistent",
        enabled_plugins: ["feishu", "claude_code"]
      )

      assert :not_found = Bundle.Registry.lookup("no_template")
    end

    test "malformed template: bundle registered, template skipped" do
      dir = Path.join(@tmp_dir, "bad_tpl")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "manifest.yaml"), manifest_yaml(name: "bad_tpl", plugins: ["feishu"]))
      File.write!(Path.join(dir, "template.yaml"), "schema_version: 99\n")

      :ok = Bundle.Loader.load_all(
        bundles_dir: @tmp_dir,
        session_templates_dir: "/nonexistent",
        enabled_plugins: ["feishu"]
      )

      assert {:ok, _} = Bundle.Registry.lookup("bad_tpl")
      assert :not_found = SessionTemplate.Registry.lookup("bad_tpl")
    end

    test "absent bundles dir: no-op" do
      :ok = Bundle.Loader.load_all(
        bundles_dir: "/nonexistent_path_for_test",
        session_templates_dir: "/also_nonexistent",
        enabled_plugins: []
      )

      assert [] = Bundle.Registry.list_all()
      assert [] = SessionTemplate.Registry.list_all()
    end
  end

  describe "load_path/2" do
    test "loads a single bundle dir" do
      dir = write_bundle!("feishu-cc", manifest_yaml(), template_yaml())

      assert {:ok, %{name: "feishu-cc", template_registered: true}} =
               Bundle.Loader.load_path(dir, enabled_plugins: ["feishu", "claude_code"])

      assert {:ok, _} = SessionTemplate.Registry.lookup("feishu-cc")
    end

    test "missing dep returns template_registered: false" do
      dir = write_bundle!("feishu-cc", manifest_yaml(), template_yaml())

      assert {:ok, %{name: "feishu-cc", template_registered: false}} =
               Bundle.Loader.load_path(dir, enabled_plugins: ["feishu"])

      assert {:ok, _} = Bundle.Registry.lookup("feishu-cc")
      assert :not_found = SessionTemplate.Registry.lookup("feishu-cc")
    end

    test "bad manifest returns error" do
      dir = Path.join(@tmp_dir, "bad")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "manifest.yaml"), "garbage:\n")
      File.write!(Path.join(dir, "template.yaml"), template_yaml())

      assert {:error, {:manifest_invalid, _, _}} =
               Bundle.Loader.load_path(dir, enabled_plugins: [])
    end
  end

  describe "unload/1" do
    test "removes bundle + its template" do
      dir = write_bundle!("feishu-cc", manifest_yaml(), template_yaml())

      {:ok, _} = Bundle.Loader.load_path(dir, enabled_plugins: ["feishu", "claude_code"])
      assert {:ok, _} = Bundle.Registry.lookup("feishu-cc")
      assert {:ok, _} = SessionTemplate.Registry.lookup("feishu-cc")

      :ok = Bundle.Loader.unload("feishu-cc")
      assert :not_found = Bundle.Registry.lookup("feishu-cc")
      assert :not_found = SessionTemplate.Registry.lookup("feishu-cc")
    end

    test "unload of unknown bundle is :ok" do
      assert :ok = Bundle.Loader.unload("ghost")
    end

    test "unload preserves operator template with same name" do
      # Bundle A registers template "foo".
      dir = write_bundle!("a-bundle", manifest_yaml(name: "a-bundle", plugins: ["feishu"]), template_yaml(name: "foo"))
      {:ok, _} = Bundle.Loader.load_path(dir, enabled_plugins: ["feishu"])
      # An operator-shipped same-name template overrides.
      operator_template = %Esr.SessionTemplate{
        schema_version: 1,
        name: "foo",
        description: "operator override",
        dependencies: %{plugins: [], bundles: []},
        channels: [],
        agents: [],
        flow: %{inbound: [], outbound: []}
      }

      SessionTemplate.Registry.register("foo", operator_template, source: :operator)

      # Unloading the bundle should NOT touch the operator-attributed template.
      :ok = Bundle.Loader.unload("a-bundle")
      assert {:ok, %{description: "operator override"}} = SessionTemplate.Registry.lookup("foo")
    end
  end

  describe "revalidate_on_plugin_enable/2" do
    test "retries skipped templates when their plugin enables" do
      dir = write_bundle!("feishu-cc", manifest_yaml(), template_yaml())

      # First load with only feishu enabled — template skipped.
      :ok = Bundle.Loader.load_all(
        bundles_dir: @tmp_dir,
        session_templates_dir: "/nonexistent",
        enabled_plugins: ["feishu"]
      )

      assert :not_found = SessionTemplate.Registry.lookup("feishu-cc")

      # claude_code enables; revalidate.
      :ok = Bundle.Loader.revalidate_on_plugin_enable("claude_code",
        enabled_plugins: ["feishu", "claude_code"]
      )

      assert {:ok, _} = SessionTemplate.Registry.lookup("feishu-cc")

      # Idempotent: re-running revalidate doesn't double-register or fail.
      :ok = Bundle.Loader.revalidate_on_plugin_enable("claude_code",
        enabled_plugins: ["feishu", "claude_code"]
      )
    end

    test "no-op when plugin not in any bundle's deps" do
      _dir = write_bundle!("feishu-cc", manifest_yaml(), template_yaml())
      :ok = Bundle.Loader.load_all(bundles_dir: @tmp_dir, session_templates_dir: "/nonexistent",
        enabled_plugins: ["feishu", "claude_code"])

      assert {:ok, _} = SessionTemplate.Registry.lookup("feishu-cc")

      :ok = Bundle.Loader.revalidate_on_plugin_enable("unrelated",
        enabled_plugins: ["feishu", "claude_code", "unrelated"]
      )

      assert {:ok, _} = SessionTemplate.Registry.lookup("feishu-cc")
    end
  end

  describe "operator session_templates dir" do
    test "loads a standalone operator template" do
      op_dir = Path.join(@tmp_dir, "operator")
      File.mkdir_p!(op_dir)

      File.write!(Path.join(op_dir, "my-custom.yaml"), """
      schema_version: 1
      name: my-custom
      description: operator-defined
      dependencies:
        plugins: [feishu]
        bundles: []
      channels:
        - alias: in
          kind: feishu.chat_proxy
      agents: []
      flow:
        inbound: []
        outbound: []
      """)

      :ok = Bundle.Loader.load_all(
        bundles_dir: "/nonexistent",
        session_templates_dir: op_dir,
        enabled_plugins: ["feishu"]
      )

      assert {:ok, %SessionTemplate{name: "my-custom"}} =
               SessionTemplate.Registry.lookup("my-custom")

      [attribution] = SessionTemplate.Registry.list_all()
      assert attribution.source == :operator
    end

    test "operator template without plugin dep met: skipped" do
      op_dir = Path.join(@tmp_dir, "operator")
      File.mkdir_p!(op_dir)

      File.write!(Path.join(op_dir, "blocked.yaml"), """
      schema_version: 1
      name: blocked
      dependencies:
        plugins: [unavailable_plugin]
      channels: []
      agents: []
      flow: {}
      """)

      :ok = Bundle.Loader.load_all(
        bundles_dir: "/nonexistent",
        session_templates_dir: op_dir,
        enabled_plugins: []
      )

      assert :not_found = SessionTemplate.Registry.lookup("blocked")
    end

    test "operator template missing name: skipped" do
      op_dir = Path.join(@tmp_dir, "operator")
      File.mkdir_p!(op_dir)

      File.write!(Path.join(op_dir, "noname.yaml"), """
      schema_version: 1
      channels: []
      agents: []
      flow: {}
      """)

      :ok = Bundle.Loader.load_all(
        bundles_dir: "/nonexistent",
        session_templates_dir: op_dir,
        enabled_plugins: []
      )

      assert [] = SessionTemplate.Registry.list_all()
    end
  end
end
