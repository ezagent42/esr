defmodule Esr.EntityRegistryTest do
  @moduledoc """
  PRD 01 F03 — thin wrapper over Elixir's Registry bound to
  `Esr.Entity.Registry` (started by Esr.Application). Verifies
  register / lookup / list_all semantics.
  """

  use ExUnit.Case, async: false

  setup do
    # The Application's Registry persists across tests; start from a clean
    # slate. PeerServers from earlier tests may still be alive (ExUnit tears
    # them down asynchronously after the owning test exits). Force-kill any
    # stray pids so the Registry receives :DOWN and cleans up promptly.
    for {_actor_id, pid} <- Esr.Entity.Registry.list_all() do
      if is_pid(pid) and Process.alive?(pid), do: Process.exit(pid, :kill)
    end

    case wait_until_empty(500) do
      :ok -> :ok
      :timeout -> flunk("Entity.Registry not empty after 5 s — stray peer pids from earlier tests")
    end

    :ok
  end

  defp wait_until_empty(0), do: :timeout

  defp wait_until_empty(tries) do
    case Esr.Entity.Registry.list_all() do
      [] ->
        :ok

      entries ->
        # Stray peers may still be appearing after test teardown — kill them.
        for {_id, pid} <- entries, is_pid(pid), Process.alive?(pid) do
          Process.exit(pid, :kill)
        end

        :timer.sleep(10)
        wait_until_empty(tries - 1)
    end
  end

  describe "lookup/1" do
    test "returns :error when actor_id not registered" do
      assert Esr.Entity.Registry.lookup("cc:sess-absent") == :error
    end

    test "returns {:ok, pid} after register/2" do
      {:ok, _} = Esr.Entity.Registry.register("cc:sess-A", self())
      assert {:ok, pid} = Esr.Entity.Registry.lookup("cc:sess-A")
      assert pid == self()
    end
  end

  describe "list_all/0" do
    test "returns empty when nothing registered" do
      assert Esr.Entity.Registry.list_all() == []
    end

    test "returns all registered pairs" do
      {:ok, _} = Esr.Entity.Registry.register("cc:sess-A", self())
      # Second actor needs a different process since the Registry is :unique
      # on {key, pid}; we spawn a trivial one.
      second_pid =
        spawn_link(fn ->
          {:ok, _} = Esr.Entity.Registry.register("cc:sess-B", self())
          receive do: (:stop -> :ok)
        end)

      # Give the spawned process a moment to register.
      :timer.sleep(10)

      entries = Esr.Entity.Registry.list_all()
      assert length(entries) == 2

      ids = entries |> Enum.map(fn {id, _pid} -> id end) |> Enum.sort()
      assert ids == ["cc:sess-A", "cc:sess-B"]

      send(second_pid, :stop)
    end
  end
end
