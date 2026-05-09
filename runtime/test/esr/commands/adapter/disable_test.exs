defmodule Esr.Commands.Adapter.DisableTest do
  @moduledoc """
  Per yaml-layout-v2 (spec § 4.6) — `/adapter:disable name=<n>` moves
  `adapters/<name>/` → `adapters/_disabled/<name>/`. Best-effort
  hot-stop of the running sidecar/peer is not asserted here (no live
  feishu sidecar in unit tests); only the on-disk move + canonical
  error codes are exercised.
  """
  use ExUnit.Case, async: false

  alias Esr.Commands.Adapter.Disable

  setup do
    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "adapter_disable_test_#{unique}")
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

  test "happy path — moves adapters/<name>/ → adapters/_disabled/<name>/", %{tmp: tmp} do
    :ok = Esr.Adapters.add("appa", "feishu", %{"app_id" => "cli_a", "app_secret" => "s"})

    cmd = %{"args" => %{"name" => "appa"}}
    assert {:ok, %{"text" => text}} = Disable.execute(cmd)
    assert text =~ "disabled adapter appa"

    refute File.exists?(Path.join([tmp, "default", "adapters", "appa", "config.yaml"]))
    assert File.exists?(Path.join([tmp, "default", "adapters", "_disabled", "appa", "config.yaml"]))
  end

  test "returns :not_found error code when instance is missing entirely" do
    cmd = %{"args" => %{"name" => "ghost"}}
    assert {:error, %{"type" => "not_found", "message" => msg}} = Disable.execute(cmd)
    assert msg =~ "ghost"
  end

  test "returns :already_disabled when entry is already in _disabled/" do
    :ok = Esr.Adapters.add("appx", "feishu", %{"app_id" => "cli_x", "app_secret" => "s"})
    :ok = Esr.Adapters.disable("appx")

    cmd = %{"args" => %{"name" => "appx"}}
    assert {:error, %{"type" => "already_disabled", "message" => msg}} = Disable.execute(cmd)
    assert msg =~ "appx"
  end

  test "returns :invalid_args when name is missing" do
    assert {:error, %{"type" => "invalid_args"}} = Disable.execute(%{"args" => %{}})
    assert {:error, %{"type" => "invalid_args"}} = Disable.execute(%{})
  end
end
