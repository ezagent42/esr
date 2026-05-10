defmodule Esr.Commands.Adapter.EnableTest do
  @moduledoc """
  Per yaml-layout-v2 (spec § 4.6) — `/adapter:enable name=<n>` is the
  inverse of `/adapter:disable`. Refresh side-effect (re-restore +
  plugin startup) calls `Esr.Application.restore_adapters_from_disk`
  which is exercised by application_restore_adapters_test; this file
  asserts only the disk move + canonical error codes.
  """
  use ExUnit.Case, async: false

  alias Esr.Commands.Adapter.Enable

  setup do
    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "adapter_enable_test_#{unique}")
    File.mkdir_p!(Path.join(tmp, "default"))

    prev_home = System.get_env("ESRD_HOME")
    System.put_env("ESRD_HOME", tmp)

    on_exit(fn ->
      if prev_home,
        do: System.put_env("ESRD_HOME", prev_home),
        else: System.delete_env("ESRD_HOME")

      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  test "happy path — moves adapters/_disabled/<name>/ → adapters/<name>/", %{tmp: tmp} do
    :ok = Esr.Adapters.add("appa", "feishu", %{"app_id" => "cli_a", "app_secret" => "s"})
    :ok = Esr.Adapters.disable("appa")

    cmd = %{"args" => %{"name" => "appa"}}
    assert {:ok, %{"text" => text}} = Enable.execute(cmd)
    assert text =~ "enabled adapter appa"

    assert File.exists?(Path.join([tmp, "default", "adapters", "appa", "config.yaml"]))
    refute File.exists?(Path.join([tmp, "default", "adapters", "_disabled", "appa", "config.yaml"]))
  end

  test "returns :not_disabled when entry is missing on the disabled side" do
    cmd = %{"args" => %{"name" => "ghost"}}
    assert {:error, %{"type" => "not_disabled", "message" => msg}} = Enable.execute(cmd)
    assert msg =~ "ghost"
  end

  test "returns :already_enabled when both active and disabled exist (collision)" do
    # Construct a manual collision: active adapters/x/ AND
    # adapters/_disabled/x/ both contain a config.yaml.
    :ok = Esr.Adapters.add("collide", "feishu", %{"app_id" => "cli_c", "app_secret" => "s"})

    disabled_path =
      Path.join([
        Esr.Paths.adapter_disabled_dir(),
        "collide",
        "config.yaml"
      ])

    File.mkdir_p!(Path.dirname(disabled_path))
    File.write!(disabled_path, "type: feishu\nconfig: {}\n")

    cmd = %{"args" => %{"name" => "collide"}}
    assert {:error, %{"type" => "already_enabled"}} = Enable.execute(cmd)
  end

  test "returns :invalid_args when name is missing" do
    assert {:error, %{"type" => "invalid_args"}} = Enable.execute(%{"args" => %{}})
    assert {:error, %{"type" => "invalid_args"}} = Enable.execute(%{})
  end
end
