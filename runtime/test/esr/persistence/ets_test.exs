defmodule Esr.Persistence.EtsTest do
  @moduledoc """
  PRD 01 F18 — ETS-backed actor state store with disk checkpoint +
  reload. Verifies: put/get/delete round-trip; save to disk then
  reload produces identical state; OTP kill-9 recovery semantics
  (simulated by clearing the table then loading from file).
  """

  use ExUnit.Case, async: false

  alias Esr.Persistence.Ets, as: Store

  setup do
    # Each test gets a unique ETS table name AND a unique registered
    # name (the application supervision tree already hosts the default
    # Esr.Persistence.Ets process + :esr_actor_states table).
    uniq = System.unique_integer([:positive])
    table = :"persist_test_#{uniq}"
    name = :"persist_test_store_#{uniq}"
    tmp_path = Path.join(System.tmp_dir!(), "esr-persist-test-#{:erlang.unique_integer([:positive])}.bin")

    start_supervised!(%{
      id: name,
      start: {Store, :start_link, [[table: table, name: name]]}
    })

    on_exit(fn -> File.rm(tmp_path) end)

    %{table: table, path: tmp_path}
  end

  describe "put/3 + get/2" do
    test "stores and retrieves actor state", %{table: table} do
      :ok = Store.put(table, "cc:sess-A", %{counter: 7, dedup: MapSet.new(["m1"])})

      assert {:ok, state} = Store.get(table, "cc:sess-A")
      assert state.counter == 7
      assert MapSet.member?(state.dedup, "m1")
    end

    test "get/2 returns :error for unknown actor_id", %{table: table} do
      assert Store.get(table, "cc:unknown") == :error
    end
  end

  describe "delete/2" do
    test "removes state for actor_id", %{table: table} do
      :ok = Store.put(table, "cc:sess-B", %{x: 1})
      :ok = Store.delete(table, "cc:sess-B")
      assert Store.get(table, "cc:sess-B") == :error
    end
  end

  describe "save_to_disk/2 + load_from_disk/2" do
    test "round-trip preserves all entries", %{table: table, path: path} do
      :ok = Store.put(table, "cc:a", %{n: 1})
      :ok = Store.put(table, "cc:b", %{n: 2, list: [:x, :y]})

      :ok = Store.save_to_disk(table, path)
      assert File.exists?(path)

      # Simulate a fresh process: clear the table, then reload from disk.
      :ok = Store.clear(table)
      assert Store.get(table, "cc:a") == :error

      {:ok, count} = Store.load_from_disk(table, path)
      assert count == 2
      assert {:ok, %{n: 1}} = Store.get(table, "cc:a")
      assert {:ok, %{n: 2, list: [:x, :y]}} = Store.get(table, "cc:b")
    end

    test "load_from_disk returns {:ok, 0} when file missing", %{table: table} do
      assert {:ok, 0} = Store.load_from_disk(table, "/tmp/does-not-exist-#{System.unique_integer()}.bin")
    end
  end
end
