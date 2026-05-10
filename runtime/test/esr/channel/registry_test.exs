defmodule Esr.Channel.RegistryTest do
  @moduledoc """
  Tests for `Esr.Channel.Registry`.

  Spec: `docs/superpowers/specs/2026-05-10-session-template-and-channel.md`,
  Phase 1.

  `async: false` because the Registry owns a named ETS table; concurrent
  tests would race on `clear/0`.
  """
  use ExUnit.Case, async: false

  alias Esr.Channel.Registry

  defmodule Mod1, do: false
  defmodule Mod2, do: false
  defmodule SomeMod, do: false

  setup do
    case start_supervised(Registry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> Registry.clear()
    end

    on_exit(fn -> Registry.clear() end)
    :ok
  end

  test "register/3 + lookup/1 round-trips a (plugin, channel_name) → module mapping" do
    :ok = Registry.register("feishu", "chat_proxy", SomeMod)
    assert {:ok, SomeMod} = Registry.lookup("feishu.chat_proxy")
  end

  test "lookup/1 with unknown kind returns :not_found" do
    assert :not_found = Registry.lookup("nonexistent.foo")
  end

  test "list_kinds/0 returns every registered (plugin, name) pair" do
    Registry.register("p", "a", Mod1)
    Registry.register("p", "b", Mod2)

    pairs = Registry.list_kinds()
    assert {"p.a", Mod1} in pairs
    assert {"p.b", Mod2} in pairs
  end

  test "register/3 with same key overwrites" do
    Registry.register("p", "a", Mod1)
    Registry.register("p", "a", Mod2)
    assert {:ok, Mod2} = Registry.lookup("p.a")
  end

  test "clear/0 empties the registry" do
    Registry.register("p", "a", Mod1)
    Registry.clear()
    assert :not_found = Registry.lookup("p.a")
  end
end
