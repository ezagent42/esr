defmodule Esr.Resource.Permission.RegistryTest do
  use ExUnit.Case, async: false

  alias Esr.Resource.Permission.Registry

  setup do
    # Registry is started by Esr.Application via Esr.Resource.Capability.Supervisor.
    # Fall back to start_supervised! only if the app-level singleton is absent
    # (e.g. in stripped-down test envs).
    if Process.whereis(Registry) == nil do
      start_supervised!(Registry)
    end

    # Reset state between tests — the app-level Registry is long-lived.
    Registry.reset()
    :ok
  end

  test "register and lookup single permission" do
    :ok = Registry.register("msg.send", declared_by: Some.Module)
    assert Registry.declared?("msg.send")
    refute Registry.declared?("msg.unknown")
    assert "msg.send" in Registry.all()
  end

  test "all/0 returns every registered permission sorted" do
    Registry.register("z.last", declared_by: M)
    Registry.register("a.first", declared_by: M)
    assert Registry.all() |> Enum.sort() == ["a.first", "z.last"]
  end
end
