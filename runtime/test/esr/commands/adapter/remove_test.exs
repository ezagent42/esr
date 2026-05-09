defmodule Esr.Commands.Adapter.RemoveTest do
  @moduledoc """
  Per yaml-layout-v2 (spec § 4.6) — `/adapter:remove` deletes
  `adapters/<name>/` and best-effort terminates the live sidecar +
  FAA peer. Sidecar termination side effects are not asserted (no
  live process) — only the on-disk delete + canonical errors.
  """
  use ExUnit.Case, async: false

  alias Esr.Commands.Adapter.Remove

  setup do
    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "adapter_remove_test_#{unique}")
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

  test "removes adapters/<name>/ entirely", %{tmp: tmp} do
    :ok = Esr.Adapters.add("doomed", "feishu", %{"app_id" => "cli_d", "app_secret" => "s"})

    cmd = %{"args" => %{"instance_id" => "doomed"}}
    assert {:ok, %{"text" => text}} = Remove.execute(cmd)
    assert text =~ "removed feishu adapter"
    assert text =~ "doomed"

    refute File.exists?(Path.join([tmp, "default", "adapters", "doomed"]))
  end

  test "returns :unknown_instance for missing instance" do
    cmd = %{"args" => %{"instance_id" => "ghost"}}

    assert {:error, %{"type" => "unknown_instance", "message" => msg}} = Remove.execute(cmd)
    assert msg =~ "ghost"
  end

  test "returns :invalid_args for missing instance_id" do
    assert {:error, %{"type" => "invalid_args"}} = Remove.execute(%{"args" => %{}})
  end
end
