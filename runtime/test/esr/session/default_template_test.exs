defmodule Esr.Session.DefaultTemplateTest do
  @moduledoc """
  Tests for `Esr.Session.DefaultTemplate`.

  Spec: `docs/superpowers/specs/2026-05-10-session-template-and-channel.md`
  §5.4. Plan Phase 5 Task 5.1.

  `async: false` — pokes the named ETS table backing
  `Esr.SessionTemplate.Registry`.
  """
  use ExUnit.Case, async: false

  alias Esr.Session.DefaultTemplate
  alias Esr.SessionTemplate.Registry, as: TemplateRegistry

  @tmp_root Path.join(System.tmp_dir!(), "esr_default_template_test")

  setup do
    File.rm_rf!(@tmp_root)
    File.mkdir_p!(@tmp_root)

    case start_supervised(TemplateRegistry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> TemplateRegistry.clear()
    end

    on_exit(fn ->
      TemplateRegistry.clear()
      File.rm_rf!(@tmp_root)
    end)

    {:ok, global_path: @tmp_root}
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

  describe "current/1" do
    test "returns :not_set when no config.yaml exists", %{global_path: path} do
      assert :not_set = DefaultTemplate.current(global_path: path)
    end

    test "returns {:ok, name} after set/1 round-trip", %{global_path: path} do
      :ok = DefaultTemplate.set("feishu-cc", global_path: path)
      assert {:ok, "feishu-cc"} = DefaultTemplate.current(global_path: path)
    end

    test "returns :not_set when key absent + other keys present", %{global_path: path} do
      # Drop a config.yaml that doesn't carry default_template — read should
      # still return :not_set rather than raising.
      File.write!(Path.join(path, "config.yaml"), "other_key: \"some value\"\n")
      assert :not_set = DefaultTemplate.current(global_path: path)
    end
  end

  describe "set/2" do
    test "writes default_template via Esr.Plugin.Config.store_layer", %{global_path: path} do
      :ok = DefaultTemplate.set("foo", global_path: path)

      content = File.read!(Path.join(path, "config.yaml"))
      assert content =~ "default_template:"
      assert content =~ "foo"

      assert {:ok, "foo"} = DefaultTemplate.current(global_path: path)
    end

    test "set/2 is idempotent — second call overwrites", %{global_path: path} do
      :ok = DefaultTemplate.set("first", global_path: path)
      :ok = DefaultTemplate.set("second", global_path: path)

      assert {:ok, "second"} = DefaultTemplate.current(global_path: path)
    end
  end

  describe "auto_elect_if_single/1" do
    test "no-op when 0 templates", %{global_path: path} do
      TemplateRegistry.clear()
      assert :ok = DefaultTemplate.auto_elect_if_single(global_path: path)
      assert :not_set = DefaultTemplate.current(global_path: path)
    end

    test "writes the lone template's name when 1 template + no default", %{global_path: path} do
      TemplateRegistry.clear()
      TemplateRegistry.register("only-one", template("only-one"), source: {:bundle, "only-one"})

      assert :ok = DefaultTemplate.auto_elect_if_single(global_path: path)
      assert {:ok, "only-one"} = DefaultTemplate.current(global_path: path)
    end

    test "no-op when default already set + 1 template", %{global_path: path} do
      :ok = DefaultTemplate.set("preset", global_path: path)

      TemplateRegistry.clear()
      TemplateRegistry.register("only-one", template("only-one"), source: {:bundle, "only-one"})

      assert :ok = DefaultTemplate.auto_elect_if_single(global_path: path)
      # Existing default preserved — auto_elect must never overwrite.
      assert {:ok, "preset"} = DefaultTemplate.current(global_path: path)
    end

    test "no-op when N>1 templates + no default", %{global_path: path} do
      TemplateRegistry.clear()
      TemplateRegistry.register("a", template("a"), source: {:bundle, "a"})
      TemplateRegistry.register("b", template("b"), source: {:bundle, "b"})

      assert :ok = DefaultTemplate.auto_elect_if_single(global_path: path)
      # Multi-template: operator must pick. Default stays unset.
      assert :not_set = DefaultTemplate.current(global_path: path)
    end

    test "idempotent — safe to call twice", %{global_path: path} do
      TemplateRegistry.clear()
      TemplateRegistry.register("solo", template("solo"), source: {:bundle, "solo"})

      assert :ok = DefaultTemplate.auto_elect_if_single(global_path: path)
      assert :ok = DefaultTemplate.auto_elect_if_single(global_path: path)
      assert {:ok, "solo"} = DefaultTemplate.current(global_path: path)
    end
  end
end
