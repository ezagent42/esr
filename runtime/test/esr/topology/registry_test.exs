defmodule Esr.Topology.RegistryTest do
  @moduledoc """
  PRD 01 F13 — Esr.Topology.Registry stores loaded artifact handles
  keyed by (name, params) for idempotent instantiation.
  """

  use ExUnit.Case, async: false

  alias Esr.Topology.Registry, as: TopoRegistry

  setup do
    # Clean slate each test — the Application's Registry persists.
    for handle <- TopoRegistry.list_all() do
      TopoRegistry.deactivate(handle)
    end
    :ok
  end

  test "register/2 returns a handle keyed by (name, params)" do
    assert {:ok, handle} =
             TopoRegistry.register("feishu-thread-session", %{"thread_id" => "foo"})

    assert handle.name == "feishu-thread-session"
    assert handle.params == %{"thread_id" => "foo"}
  end

  test "registering the same (name, params) twice returns the same handle" do
    {:ok, a} =
      TopoRegistry.register("feishu-thread-session", %{"thread_id" => "foo"})

    {:ok, b} =
      TopoRegistry.register("feishu-thread-session", %{"thread_id" => "foo"})

    assert a == b
  end

  test "different params produce different handles" do
    {:ok, a} = TopoRegistry.register("cmd", %{"t" => "a"})
    {:ok, b} = TopoRegistry.register("cmd", %{"t" => "b"})
    assert a != b
  end

  test "lookup/2 returns the registered handle" do
    {:ok, handle} = TopoRegistry.register("my-cmd", %{"x" => "1"})
    assert {:ok, ^handle} = TopoRegistry.lookup("my-cmd", %{"x" => "1"})
  end

  test "lookup/2 returns :error for absent key" do
    assert :error = TopoRegistry.lookup("missing", %{})
  end

  test "list_all/0 returns every registered handle" do
    {:ok, _} = TopoRegistry.register("a", %{})
    {:ok, _} = TopoRegistry.register("b", %{})
    assert length(TopoRegistry.list_all()) == 2
  end

  test "deactivate/1 removes the handle" do
    {:ok, handle} = TopoRegistry.register("c", %{})
    assert :ok = TopoRegistry.deactivate(handle)
    assert :error = TopoRegistry.lookup("c", %{})
  end

  test "concurrent registers for the same (name, params) are atomic (S7)" do
    # Reviewer S7: the old impl used lookup-then-insert, which could race.
    # Spawn many tasks all registering the same key with DIFFERENT peer_ids
    # lists; exactly one must win, and list_all/0 must return a single row.
    name = "ic-race"
    params = %{"n" => "42"}

    tasks =
      for i <- 1..32 do
        Task.async(fn ->
          TopoRegistry.register(name, params, ["peer-#{i}"])
        end)
      end

    handles = Task.await_many(tasks, 2_000) |> Enum.map(fn {:ok, h} -> h end)

    # All callers receive the SAME handle (winner's peer_ids).
    assert Enum.uniq(handles) |> length() == 1

    # Exactly one row for this (name, params) in the ETS table.
    assert length(TopoRegistry.list_all()) == 1
  end
end
