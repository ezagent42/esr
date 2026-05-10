defmodule Mix.Tasks.Esr.CheckBundlesTest do
  @moduledoc """
  Phase 8 (2026-05-10): tests for the `mix esr.check_bundles` CI gate.

  Spec: docs/superpowers/specs/2026-05-10-session-template-and-channel.md
  Phase 8 Task 8.3.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Esr.CheckBundles

  describe "check/1 against the in-tree state" do
    test "returns :ok against the live runtime/lib/esr/bundles/ + plugins/" do
      # Phase 8 commit baseline ships the feishu-cc bundle whose deps
      # (feishu, claude_code) have plugin manifests in-tree. Right after
      # baseline the CI gate must pass.
      assert :ok = CheckBundles.check()
    end
  end

  describe "check/1 with explicit roots — happy path" do
    test "passes when a bundle's deps + channel kinds + agent kinds all resolve" do
      bundles_root = make_tmpdir("bundles_happy")
      plugins_root = make_tmpdir("plugins_happy")

      # plugin "p1": one channel "ch", one agent_kind "ag"
      write_plugin(plugins_root, "p1", "ch", "ag")

      write_bundle(bundles_root, "good", %{
        name: "good",
        deps: ["p1"],
        channel_kinds: ["p1.ch"],
        agent_kinds: ["p1.ag"]
      })

      assert :ok =
               CheckBundles.check(
                 bundles_root: bundles_root,
                 plugins_root: plugins_root
               )
    end
  end

  describe "check/1 with explicit roots — failure paths" do
    test "fails with :dep_plugin_unknown when a manifest dep is not an in-tree plugin" do
      bundles_root = make_tmpdir("bundles_dep_unknown")
      plugins_root = make_tmpdir("plugins_dep_unknown")

      write_plugin(plugins_root, "p1", "ch", "ag")

      write_bundle(bundles_root, "bad-dep", %{
        name: "bad-dep",
        deps: ["nonexistent_plugin"],
        channel_kinds: ["p1.ch"],
        agent_kinds: ["p1.ag"]
      })

      assert {:error, errors} =
               CheckBundles.check(
                 bundles_root: bundles_root,
                 plugins_root: plugins_root
               )

      assert {"bad-dep", :dep_plugin_unknown, "nonexistent_plugin"} in errors
    end

    test "fails with :unknown_channel_kind when a template references an unknown channel kind" do
      bundles_root = make_tmpdir("bundles_unknown_channel")
      plugins_root = make_tmpdir("plugins_unknown_channel")

      write_plugin(plugins_root, "p1", "ch", "ag")

      write_bundle(bundles_root, "bad-channel", %{
        name: "bad-channel",
        deps: ["p1"],
        channel_kinds: ["p1.does_not_exist"],
        agent_kinds: ["p1.ag"]
      })

      assert {:error, errors} =
               CheckBundles.check(
                 bundles_root: bundles_root,
                 plugins_root: plugins_root
               )

      assert {"bad-channel", :unknown_channel_kind, "p1.does_not_exist"} in errors
    end

    test "fails with :unknown_agent_kind when a template references an unknown agent kind" do
      bundles_root = make_tmpdir("bundles_unknown_agent")
      plugins_root = make_tmpdir("plugins_unknown_agent")

      write_plugin(plugins_root, "p1", "ch", "ag")

      write_bundle(bundles_root, "bad-agent", %{
        name: "bad-agent",
        deps: ["p1"],
        channel_kinds: ["p1.ch"],
        agent_kinds: ["p1.does_not_exist"]
      })

      assert {:error, errors} =
               CheckBundles.check(
                 bundles_root: bundles_root,
                 plugins_root: plugins_root
               )

      assert {"bad-agent", :unknown_agent_kind, "p1.does_not_exist"} in errors
    end

    test "fails with :manifest_parse_failed when manifest.yaml is malformed" do
      bundles_root = make_tmpdir("bundles_bad_manifest")
      plugins_root = make_tmpdir("plugins_bad_manifest")

      bundle_dir = Path.join(bundles_root, "broken")
      File.mkdir_p!(bundle_dir)
      File.write!(Path.join(bundle_dir, "manifest.yaml"), "not: a valid manifest")
      File.write!(Path.join(bundle_dir, "template.yaml"), "schema_version: 1\nname: foo\n")

      assert {:error, errors} =
               CheckBundles.check(
                 bundles_root: bundles_root,
                 plugins_root: plugins_root
               )

      assert Enum.any?(errors, fn
               {"broken", :manifest_parse_failed, _} -> true
               _ -> false
             end)
    end

    test "skips operator extra_roots gracefully when the path doesn't exist" do
      bundles_root = make_tmpdir("bundles_extra_missing")
      plugins_root = make_tmpdir("plugins_extra_missing")

      # Empty bundles_root; missing extra path → still :ok.
      missing = Path.join(System.tmp_dir!(), "nonexistent_#{System.unique_integer([:positive])}")

      assert :ok =
               CheckBundles.check(
                 bundles_root: bundles_root,
                 plugins_root: plugins_root,
                 extra_roots: [missing]
               )
    end
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp make_tmpdir(label) do
    path = Path.join(System.tmp_dir!(), "esr_check_bundles_#{label}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit_rm(path)
    path
  end

  defp on_exit_rm(path) do
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(path) end)
  end

  # Writes a minimal plugin manifest with one channel + one agent_kind.
  defp write_plugin(root, name, channel_name, agent_kind_name) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "manifest.yaml"), """
    name: #{name}
    version: 0.1.0
    description: test plugin

    channels:
      - name: #{channel_name}
        module: Esr.Plugins.Stub.NoOp

    agent_kinds:
      - name: #{agent_kind_name}
        description: stub
        pipeline:
          inbound:
            - { name: stub, impl: Esr.Plugins.Stub.NoOp }
          outbound:
            - stub
        capabilities_required: []

    depends_on:
      core: ">= 0.1.0"
      plugins: []

    declares:
      entities: []
    """)
  end

  # Writes a minimal bundle dir with manifest + template referencing the
  # given channel + agent kinds.
  defp write_bundle(root, dir_name, %{
         name: name,
         deps: deps,
         channel_kinds: channel_kinds,
         agent_kinds: agent_kinds
       }) do
    dir = Path.join(root, dir_name)
    File.mkdir_p!(dir)

    deps_yaml =
      case deps do
        [] -> "[]"
        list -> "[" <> Enum.join(list, ", ") <> "]"
      end

    File.write!(Path.join(dir, "manifest.yaml"), """
    schema_version: 1
    name: #{name}
    version: 0.1.0
    description: test bundle
    dependencies:
      plugins: #{deps_yaml}
      bundles: []
    """)

    channel_block =
      channel_kinds
      |> Enum.with_index()
      |> Enum.map(fn {kind, i} ->
        "  - alias: ch#{i}\n    kind: #{kind}\n    config: {}"
      end)
      |> Enum.join("\n")

    agent_block =
      agent_kinds
      |> Enum.with_index()
      |> Enum.map(fn {kind, i} ->
        "  - kind: #{kind}\n    name: ag#{i}\n    consumes: []"
      end)
      |> Enum.join("\n")

    File.write!(Path.join(dir, "template.yaml"), """
    schema_version: 1
    name: #{name}
    description: test
    channels:
    #{channel_block}

    agents:
    #{agent_block}

    flow:
      inbound: []
      outbound: []
    """)
  end
end
