defmodule Esr.Resource.Workspace.NameIndexTest do
  use ExUnit.Case, async: true
  alias Esr.Resource.Workspace.NameIndex

  setup do
    table = :"ni_test_#{:rand.uniform(1_000_000_000)}"
    {:ok, _pid} = NameIndex.start_link(table: table)
    %{table: table}
  end

  test "put + lookup by name + by id", %{table: table} do
    NameIndex.put(table, "esr-dev", "uuid-1")
    NameIndex.put(table, "scratch", "uuid-2")

    assert NameIndex.id_for_name(table, "esr-dev") == {:ok, "uuid-1"}
    assert NameIndex.name_for_id(table, "uuid-1") == {:ok, "esr-dev"}
    assert NameIndex.id_for_name(table, "scratch") == {:ok, "uuid-2"}
    assert NameIndex.name_for_id(table, "uuid-2") == {:ok, "scratch"}
  end

  test "id_for_name on unknown returns :not_found", %{table: table} do
    assert NameIndex.id_for_name(table, "ghost") == :not_found
    assert NameIndex.name_for_id(table, "ghost-uuid") == :not_found
  end

  test "rename: keep id, change name", %{table: table} do
    NameIndex.put(table, "esr-dev", "uuid-1")
    NameIndex.rename(table, "esr-dev", "esr-prod")

    assert NameIndex.id_for_name(table, "esr-dev") == :not_found
    assert NameIndex.id_for_name(table, "esr-prod") == {:ok, "uuid-1"}
    assert NameIndex.name_for_id(table, "uuid-1") == {:ok, "esr-prod"}
  end

  test "delete by id", %{table: table} do
    NameIndex.put(table, "esr-dev", "uuid-1")
    NameIndex.delete_by_id(table, "uuid-1")

    assert NameIndex.id_for_name(table, "esr-dev") == :not_found
    assert NameIndex.name_for_id(table, "uuid-1") == :not_found
  end

  test "all/1 returns all (name, id) tuples", %{table: table} do
    NameIndex.put(table, "a", "uuid-a")
    NameIndex.put(table, "b", "uuid-b")
    pairs = NameIndex.all(table) |> Enum.sort()
    assert pairs == [{"a", "uuid-a"}, {"b", "uuid-b"}]
  end

  test "duplicate name with different id rejects", %{table: table} do
    NameIndex.put(table, "esr-dev", "uuid-1")
    assert {:error, :name_exists} = NameIndex.put(table, "esr-dev", "uuid-2")
  end

  test "duplicate id with different name rejects", %{table: table} do
    NameIndex.put(table, "a", "uuid-1")
    assert {:error, :id_exists} = NameIndex.put(table, "b", "uuid-1")
  end
end
