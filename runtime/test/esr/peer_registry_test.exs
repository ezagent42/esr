defmodule Esr.PeerRegistryTest do
  @moduledoc """
  PRD 01 F03 — thin wrapper over Elixir's Registry bound to
  `Esr.PeerRegistry` (started by Esr.Application). Verifies
  register / lookup / list_all semantics.
  """

  use ExUnit.Case, async: false

  setup do
    # The Application's Registry persists across tests; start from a clean slate
    # by unregistering every key. Registry doesn't expose "clear all" so we
    # enumerate and unregister.
    for {actor_id, _pid} <- Esr.PeerRegistry.list_all() do
      Registry.unregister(Esr.PeerRegistry, actor_id)
    end

    :ok
  end

  describe "lookup/1" do
    test "returns :error when actor_id not registered" do
      assert Esr.PeerRegistry.lookup("cc:sess-absent") == :error
    end

    test "returns {:ok, pid} after register/2" do
      {:ok, _} = Esr.PeerRegistry.register("cc:sess-A", self())
      assert {:ok, pid} = Esr.PeerRegistry.lookup("cc:sess-A")
      assert pid == self()
    end
  end

  describe "list_all/0" do
    test "returns empty when nothing registered" do
      assert Esr.PeerRegistry.list_all() == []
    end

    test "returns all registered pairs" do
      {:ok, _} = Esr.PeerRegistry.register("cc:sess-A", self())
      # Second actor needs a different process since the Registry is :unique
      # on {key, pid}; we spawn a trivial one.
      second_pid =
        spawn_link(fn ->
          {:ok, _} = Esr.PeerRegistry.register("cc:sess-B", self())
          receive do: (:stop -> :ok)
        end)

      # Give the spawned process a moment to register.
      :timer.sleep(10)

      entries = Esr.PeerRegistry.list_all()
      assert length(entries) == 2

      ids = entries |> Enum.map(fn {id, _pid} -> id end) |> Enum.sort()
      assert ids == ["cc:sess-A", "cc:sess-B"]

      send(second_pid, :stop)
    end
  end
end
