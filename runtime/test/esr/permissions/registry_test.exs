defmodule Esr.Permissions.RegistryTest do
  use ExUnit.Case, async: false

  alias Esr.Permissions.Registry

  setup do
    start_supervised!(Registry)
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
