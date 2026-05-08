defmodule Esr.Entity.User.NameIndexTest do
  use ExUnit.Case, async: false
  alias Esr.Entity.User.NameIndex

  @table :esr_user_name_index_test

  setup do
    case NameIndex.start_link(table: @table) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Clear state between tests by deleting all objects from both ETS tables
    :ets.delete_all_objects(:"#{@table}_name_to_id")
    :ets.delete_all_objects(:"#{@table}_id_to_name")
    :ok
  end

  test "put and id_for_name" do
    assert :ok = NameIndex.put(@table, "linyilun", "uuid-001")
    assert {:ok, "uuid-001"} = NameIndex.id_for_name(@table, "linyilun")
  end

  test "name_for_id returns name" do
    NameIndex.put(@table, "alice", "uuid-002")
    assert {:ok, "alice"} = NameIndex.name_for_id(@table, "uuid-002")
  end

  test "id_for_name returns :not_found for unknown" do
    assert :not_found = NameIndex.id_for_name(@table, "nobody")
  end

  test "name_for_id returns :not_found for unknown" do
    assert :not_found = NameIndex.name_for_id(@table, "uuid-999")
  end

  test "put rejects duplicate name" do
    NameIndex.put(@table, "bob", "uuid-003")
    assert {:error, :name_exists} = NameIndex.put(@table, "bob", "uuid-004")
  end

  test "put rejects duplicate id" do
    NameIndex.put(@table, "carol", "uuid-005")
    assert {:error, :id_exists} = NameIndex.put(@table, "dave", "uuid-005")
  end

  test "rename updates both directions" do
    NameIndex.put(@table, "eve", "uuid-006")
    assert :ok = NameIndex.rename(@table, "eve", "eva")
    assert {:ok, "uuid-006"} = NameIndex.id_for_name(@table, "eva")
    assert :not_found = NameIndex.id_for_name(@table, "eve")
  end

  test "rename returns :not_found for unknown name" do
    assert {:error, :not_found} = NameIndex.rename(@table, "ghost", "new-name")
  end

  test "rename returns :name_exists if new name taken" do
    NameIndex.put(@table, "frank", "uuid-007")
    NameIndex.put(@table, "grace", "uuid-008")
    assert {:error, :name_exists} = NameIndex.rename(@table, "frank", "grace")
  end

  test "delete_by_id removes both directions" do
    NameIndex.put(@table, "hal", "uuid-009")
    assert :ok = NameIndex.delete_by_id(@table, "uuid-009")
    assert :not_found = NameIndex.id_for_name(@table, "hal")
    assert :not_found = NameIndex.name_for_id(@table, "uuid-009")
  end

  test "all returns all name→id pairs" do
    NameIndex.put(@table, "ivan", "uuid-010")
    NameIndex.put(@table, "judy", "uuid-011")
    pairs = NameIndex.all(@table) |> Enum.sort()
    assert {"ivan", "uuid-010"} in pairs
    assert {"judy", "uuid-011"} in pairs
  end
end
