defmodule Esr.Bundle.RegistryTest do
  @moduledoc """
  Tests for `Esr.Bundle.Registry`.

  Spec: `docs/superpowers/specs/2026-05-10-session-template-and-channel.md`
  §5.3, §5.5. Phase 4 (Task 4.3).

  `async: false` because the Registry owns a named ETS table; concurrent
  tests would race on `clear/0`.
  """
  use ExUnit.Case, async: false

  alias Esr.Bundle.Registry

  setup do
    case start_supervised(Registry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> Registry.clear()
    end

    on_exit(fn -> Registry.clear() end)
    :ok
  end

  defp manifest(name) do
    %Esr.Bundle.Manifest{
      schema_version: 1,
      name: name,
      version: "0.1.0",
      description: "test bundle " <> name,
      dependencies: %{plugins: [], bundles: []},
      path: nil
    }
  end

  test "register/3 + lookup/1 round-trips" do
    m = manifest("foo")
    :ok = Registry.register("foo", m, "/tmp/foo")
    assert {:ok, %{manifest: ^m, source_path: "/tmp/foo"}} = Registry.lookup("foo")
  end

  test "lookup/1 unknown returns :not_found" do
    assert :not_found = Registry.lookup("ghost")
  end

  test "list_all/0 returns every bundle name" do
    Registry.register("a", manifest("a"), "/tmp/a")
    Registry.register("b", manifest("b"), "/tmp/b")
    assert ["a", "b"] = Enum.sort(Registry.list_all())
  end

  test "register/3 same name overwrites" do
    Registry.register("a", manifest("a"), "/tmp/a-old")
    Registry.register("a", manifest("a"), "/tmp/a-new")
    assert {:ok, %{source_path: "/tmp/a-new"}} = Registry.lookup("a")
  end

  test "unregister/1 removes the entry" do
    Registry.register("a", manifest("a"), "/tmp/a")
    Registry.unregister("a")
    assert :not_found = Registry.lookup("a")
  end

  test "clear/0 empties the registry" do
    Registry.register("a", manifest("a"), "/tmp/a")
    Registry.clear()
    assert :not_found = Registry.lookup("a")
    assert [] == Registry.list_all()
  end
end
