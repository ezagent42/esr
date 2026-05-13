defmodule Esr.Commands.Plugin.InstallTest do
  @moduledoc """
  Tests for `Esr.Commands.Plugin.Install` — covers BOTH the existing
  plugin path and the new bundle path added in Phase 4 (Task 4.5).

  Spec: `docs/superpowers/specs/2026-05-10-session-template-and-channel.md`
  §5.5 step 3 (bundle vs plugin discrimination + conflict rejection).

  `async: false` because the test mutates `Application` env to redirect
  the install destination to a tmp dir, and writes into named-ETS-backed
  registries.
  """
  use ExUnit.Case, async: false

  alias Esr.Bundle
  alias Esr.SessionTemplate

  @tmp_dir Path.join(System.tmp_dir!(), "esr_plugin_install_test")

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)

    plugin_dest = Path.join(@tmp_dir, "plugins")
    bundle_dest = Path.join(@tmp_dir, "bundles")
    File.mkdir_p!(plugin_dest)
    File.mkdir_p!(bundle_dest)

    Application.put_env(:esr, :plugin_install_plugins_dir, plugin_dest)
    Application.put_env(:esr, :plugin_install_bundles_dir, bundle_dest)
    prev_enabled = Application.get_env(:esr, :enabled_plugins, [])
    Application.put_env(:esr, :enabled_plugins, ["feishu", "claude_code"])

    case start_supervised(Bundle.Registry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> Bundle.Registry.clear()
    end

    case start_supervised(SessionTemplate.Registry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> SessionTemplate.Registry.clear()
    end

    on_exit(fn ->
      Application.delete_env(:esr, :plugin_install_plugins_dir)
      Application.delete_env(:esr, :plugin_install_bundles_dir)
      Application.put_env(:esr, :enabled_plugins, prev_enabled)
      Bundle.Registry.clear()
      SessionTemplate.Registry.clear()
      File.rm_rf!(@tmp_dir)
    end)

    %{plugin_dest: plugin_dest, bundle_dest: bundle_dest}
  end

  defp write_bundle_source!(name) do
    src = Path.join(@tmp_dir, "src_" <> name)
    File.mkdir_p!(src)

    File.write!(Path.join(src, "manifest.yaml"), """
    schema_version: 1
    name: #{name}
    version: 0.1.0
    description: test bundle #{name}
    dependencies:
      plugins: [feishu, claude_code]
      bundles: []
    """)

    File.write!(Path.join(src, "template.yaml"), """
    schema_version: 1
    name: #{name}
    channels:
      - alias: in
        kind: feishu.chat_proxy
        config: {}
      - alias: cc
        kind: claude_code.mcp_stdio
        config: {}
    agents:
      - kind: claude_code.cc
        name: <runtime>
        consumes: [cc]
    flow:
      inbound:
        - source: in.text
          pipeline:
            - "<route_to_agent>"
      outbound:
        - source: <agent>.reply
          sink: in.send
    """)

    src
  end

  describe "bundle install path (Task 4.5)" do
    test "happy path: copies + registers + returns success text", ctx do
      src = write_bundle_source!("test-bundle-happy")

      cmd = %{"submitted_by" => "tester", "args" => %{"source" => src}}
      assert {:ok, %{"text" => text}} = Esr.Commands.Plugin.Install.execute(cmd)

      assert text =~ "installed bundle: test-bundle-happy"
      assert text =~ "template registered"

      assert File.dir?(Path.join(ctx.bundle_dest, "test-bundle-happy"))
      assert {:ok, _} = Bundle.Registry.lookup("test-bundle-happy")
      assert {:ok, _} = SessionTemplate.Registry.lookup("test-bundle-happy")
    end

    test "missing plugin dep: bundle copied + registered, template skipped" do
      Application.put_env(:esr, :enabled_plugins, ["feishu"])
      src = write_bundle_source!("test-bundle-skip")

      cmd = %{"submitted_by" => "tester", "args" => %{"source" => src}}
      assert {:ok, %{"text" => text}} = Esr.Commands.Plugin.Install.execute(cmd)

      assert text =~ "installed bundle: test-bundle-skip"
      assert text =~ "template SKIPPED"
      assert text =~ "claude_code"

      assert {:ok, _} = Bundle.Registry.lookup("test-bundle-skip")
      assert :not_found = SessionTemplate.Registry.lookup("test-bundle-skip")
    end

    test "name collision rejected", ctx do
      src = write_bundle_source!("test-bundle-collide")
      File.mkdir_p!(Path.join(ctx.bundle_dest, "test-bundle-collide"))

      cmd = %{"submitted_by" => "tester", "args" => %{"source" => src}}
      assert {:ok, %{"text" => text}} = Esr.Commands.Plugin.Install.execute(cmd)
      assert text =~ "bundle already installed"
    end

    test "malformed manifest: rejected with structured error" do
      src = Path.join(@tmp_dir, "src_bad")
      File.mkdir_p!(src)
      File.write!(Path.join(src, "manifest.yaml"), "schema_version: 99\nname: x\nversion: 1\ndependencies:\n  plugins: [foo]\n")
      File.write!(Path.join(src, "template.yaml"), "schema_version: 1\nchannels: []\nagents: []\nflow: {}\n")

      cmd = %{"submitted_by" => "tester", "args" => %{"source" => src}}
      assert {:ok, %{"text" => text}} = Esr.Commands.Plugin.Install.execute(cmd)
      assert text =~ "bundle manifest invalid"
      assert text =~ "schema_version_mismatch"
    end
  end

  describe "bundle vs plugin conflict (spec §5.5 step 3)" do
    test "template.yaml + plugin-shape manifest (channels:) is rejected" do
      src = Path.join(@tmp_dir, "src_conflict_channels")
      File.mkdir_p!(src)

      # Plugin-shape manifest with top-level `channels:` block AND a
      # template.yaml present in the same dir → conflict.
      File.write!(Path.join(src, "manifest.yaml"), """
      name: conflict-bundle
      version: 0.1.0
      channels:
        - name: foo
          module: Esr.Plugins.ClaudeCode.Channels.Mcp
      """)

      File.write!(Path.join(src, "template.yaml"), "schema_version: 1\nchannels: []\nagents: []\nflow: {}\n")

      cmd = %{"submitted_by" => "tester", "args" => %{"source" => src}}
      assert {:ok, %{"text" => text}} = Esr.Commands.Plugin.Install.execute(cmd)
      assert text =~ "bundle_and_plugin_conflict"
      assert text =~ "channels"
    end

    test "template.yaml + plugin-shape manifest (declares:) is rejected" do
      src = Path.join(@tmp_dir, "src_conflict_declares")
      File.mkdir_p!(src)

      File.write!(Path.join(src, "manifest.yaml"), """
      name: conflict-bundle-2
      version: 0.1.0
      declares:
        capabilities: [foo/bar]
      """)

      File.write!(Path.join(src, "template.yaml"), "schema_version: 1\nchannels: []\nagents: []\nflow: {}\n")

      cmd = %{"submitted_by" => "tester", "args" => %{"source" => src}}
      assert {:ok, %{"text" => text}} = Esr.Commands.Plugin.Install.execute(cmd)
      assert text =~ "bundle_and_plugin_conflict"
      assert text =~ "declares"
    end
  end

  describe "plugin install path unchanged" do
    test "plugin source (no template.yaml) still installs as plugin", ctx do
      src = Path.join(@tmp_dir, "src_plugin")
      File.mkdir_p!(src)

      File.write!(Path.join(src, "manifest.yaml"), """
      name: legacy-plugin
      version: 0.0.1
      depends_on:
        core: ">= 0.0.0"
        plugins: []
      declares: {}
      """)

      cmd = %{"submitted_by" => "tester", "args" => %{"source" => src}}
      assert {:ok, %{"text" => text}} = Esr.Commands.Plugin.Install.execute(cmd)
      assert text =~ "installed plugin: legacy-plugin"

      # Should land in plugins_dir, not bundles_dir.
      assert File.dir?(Path.join(ctx.plugin_dest, "legacy-plugin"))
      assert :not_found = Bundle.Registry.lookup("legacy-plugin")
    end
  end

  describe "common error paths" do
    test "missing source dir" do
      cmd = %{"submitted_by" => "tester", "args" => %{"source" => "/nonexistent_for_sure"}}
      assert {:ok, %{"text" => text}} = Esr.Commands.Plugin.Install.execute(cmd)
      assert text =~ "source not found"
    end

    test "missing manifest.yaml" do
      src = Path.join(@tmp_dir, "src_empty")
      File.mkdir_p!(src)
      cmd = %{"submitted_by" => "tester", "args" => %{"source" => src}}
      assert {:ok, %{"text" => text}} = Esr.Commands.Plugin.Install.execute(cmd)
      assert text =~ "no manifest.yaml"
    end

    test "missing source arg" do
      cmd = %{"submitted_by" => "tester", "args" => %{}}
      assert {:ok, %{"text" => text}} = Esr.Commands.Plugin.Install.execute(cmd)
      assert text =~ "usage:"
    end
  end
end
