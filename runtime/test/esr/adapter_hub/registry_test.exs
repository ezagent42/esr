defmodule Esr.AdapterHub.RegistryTest do
  @moduledoc """
  PRD 01 F08 — Esr.AdapterHub.Registry binds adapter Phoenix topics
  (adapter:<name>/<instance_id>) to the owning actor_id, so inbound
  events from a channel can route to the correct PeerServer.
  """

  use ExUnit.Case, async: false

  alias Esr.AdapterHub.Registry, as: Reg

  setup do
    # AdapterHub.Supervisor (started by the Application) owns the Registry
    # for the whole test run. Clean up bindings between tests so cases
    # don't see stale state.
    for {topic, _} <- Reg.list(), do: Reg.unbind(topic)
    :ok
  end

  describe "bind/2" do
    test "binds topic to actor_id" do
      :ok = Reg.bind("adapter:feishu/shared", "feishu-app:cli_xxx")
      assert {:ok, "feishu-app:cli_xxx"} = Reg.lookup("adapter:feishu/shared")
    end

    test "re-binding same topic replaces the previous actor_id" do
      :ok = Reg.bind("adapter:feishu/shared", "a")
      :ok = Reg.bind("adapter:feishu/shared", "b")
      assert {:ok, "b"} = Reg.lookup("adapter:feishu/shared")
    end
  end

  describe "unbind/1" do
    test "removes the binding" do
      :ok = Reg.bind("adapter:cc_tmux/t1", "cc:t1")
      :ok = Reg.unbind("adapter:cc_tmux/t1")
      assert Reg.lookup("adapter:cc_tmux/t1") == :error
    end

    test "unbinding a non-existent topic returns :ok (idempotent)" do
      assert :ok = Reg.unbind("adapter:none/x")
    end
  end

  describe "lookup/1" do
    test "returns :error for unknown topic" do
      assert Reg.lookup("adapter:unknown/42") == :error
    end
  end

  describe "list/0" do
    test "enumerates current bindings" do
      :ok = Reg.bind("adapter:feishu/a", "aa")
      :ok = Reg.bind("adapter:cc_tmux/b", "bb")

      list = Reg.list()
      assert length(list) >= 2
      assert {"adapter:feishu/a", "aa"} in list
      assert {"adapter:cc_tmux/b", "bb"} in list
    end
  end

  describe "process monitoring (S5)" do
    test "bindings belonging to a dead actor are cleaned up" do
      # Spawn a simple process and register it in PeerRegistry under
      # an actor_id so AdapterHub.Registry can monitor it when we bind.
      test_pid = self()

      owner_pid =
        spawn(fn ->
          {:ok, _} = Registry.register(Esr.PeerRegistry, "owner:1", nil)
          send(test_pid, :owner_registered)

          receive do
            :die -> :ok
          end
        end)

      assert_receive :owner_registered, 500

      :ok = Reg.bind("adapter:feishu/monitored", "owner:1")
      assert {:ok, "owner:1"} = Reg.lookup("adapter:feishu/monitored")

      # Kill the owner; its Registry entry clears async and AdapterHub
      # must drop the binding via DOWN handling.
      ref = Process.monitor(owner_pid)
      send(owner_pid, :die)
      assert_receive {:DOWN, ^ref, :process, ^owner_pid, _}, 500

      # Poll briefly for the async DOWN message to reach the registry.
      wait_until_unbound("adapter:feishu/monitored", 50)
      assert Reg.lookup("adapter:feishu/monitored") == :error
    end

    test "bindings for unknown actor_id (never registered) stay without a monitor" do
      # If the owner isn't in PeerRegistry at bind time there's no pid
      # to monitor. The binding is still stored (idempotent upsert).
      :ok = Reg.bind("adapter:feishu/ghost", "owner:ghost")
      assert {:ok, "owner:ghost"} = Reg.lookup("adapter:feishu/ghost")
    end
  end

  defp wait_until_unbound(_topic, 0), do: :ok

  defp wait_until_unbound(topic, tries) do
    case Reg.lookup(topic) do
      :error -> :ok
      {:ok, _} ->
        Process.sleep(10)
        wait_until_unbound(topic, tries - 1)
    end
  end
end
