defmodule Esr.SessionTemplate.RegistryTest do
  @moduledoc """
  Tests for `Esr.SessionTemplate.Registry`.

  Spec: `docs/superpowers/specs/2026-05-10-session-template-and-channel.md`
  §5.3, §5.5. Phase 4 (Task 4.3).

  `async: false` because the Registry owns a named ETS table; concurrent
  tests would race on `clear/0`.
  """
  use ExUnit.Case, async: false

  alias Esr.SessionTemplate.Registry

  setup do
    case start_supervised(Registry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> Registry.clear()
    end

    on_exit(fn -> Registry.clear() end)
    :ok
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

  test "register/3 + lookup/1 round-trips a bundle template" do
    t = template("feishu-cc")
    :ok = Registry.register("feishu-cc", t, source: {:bundle, "feishu-cc"})
    assert {:ok, ^t} = Registry.lookup("feishu-cc")
  end

  test "register/3 + lookup/1 round-trips an operator template" do
    t = template("custom")
    :ok = Registry.register("custom", t, source: :operator)
    assert {:ok, ^t} = Registry.lookup("custom")
  end

  test "register/3 missing source: raises" do
    t = template("x")
    assert_raise KeyError, fn -> Registry.register("x", t, []) end
  end

  test "lookup/1 unknown returns :not_found" do
    assert :not_found = Registry.lookup("ghost")
  end

  test "list_all/0 returns every name + source" do
    Registry.register("a", template("a"), source: {:bundle, "a"})
    Registry.register("b", template("b"), source: :operator)

    pairs = Registry.list_all()
    by_name = Enum.into(pairs, %{}, fn %{name: n, source: s} -> {n, s} end)
    assert by_name["a"] == {:bundle, "a"}
    assert by_name["b"] == :operator
  end

  test "register/3 same name overwrites (operator override of bundle)" do
    Registry.register("foo", template("foo-bundle"), source: {:bundle, "foo"})
    Registry.register("foo", template("foo-operator"), source: :operator)
    assert {:ok, %{name: "foo-operator"}} = Registry.lookup("foo")

    [%{name: "foo", source: source}] = Registry.list_all()
    assert source == :operator
  end

  test "unregister/1 removes" do
    Registry.register("foo", template("foo"), source: :operator)
    Registry.unregister("foo")
    assert :not_found = Registry.lookup("foo")
  end
end
