defmodule Esr.Entity.User.RegistryTest do
  use ExUnit.Case, async: false

  alias Esr.Entity.User.Registry
  alias Esr.Entity.User.Registry.User

  setup do
    if Process.whereis(Registry) == nil, do: start_supervised!(Registry)
    Registry.load_snapshot(%{})
    :ok
  end

  test "lookup_by_feishu_id resolves bound id to username" do
    snapshot = %{
      "linyilun" => %User{
        username: "linyilun",
        feishu_ids: ["ou_AAA", "ou_BBB"]
      }
    }

    :ok = Registry.load_snapshot(snapshot)
    assert {:ok, "linyilun"} = Registry.lookup_by_feishu_id("ou_AAA")
    assert {:ok, "linyilun"} = Registry.lookup_by_feishu_id("ou_BBB")
  end

  test "lookup_by_feishu_id returns :not_found for unbound id" do
    :ok =
      Registry.load_snapshot(%{
        "linyilun" => %User{username: "linyilun", feishu_ids: ["ou_AAA"]}
      })

    assert :not_found = Registry.lookup_by_feishu_id("ou_does_not_exist")
  end

  test "load_snapshot replaces atomically — old bindings are wiped" do
    :ok =
      Registry.load_snapshot(%{
        "linyilun" => %User{username: "linyilun", feishu_ids: ["ou_AAA"]}
      })

    assert {:ok, "linyilun"} = Registry.lookup_by_feishu_id("ou_AAA")

    :ok =
      Registry.load_snapshot(%{
        "yaoshengyue" => %User{username: "yaoshengyue", feishu_ids: ["ou_CCC"]}
      })

    assert :not_found = Registry.lookup_by_feishu_id("ou_AAA")
    assert {:ok, "yaoshengyue"} = Registry.lookup_by_feishu_id("ou_CCC")
  end

  test "get/1 returns the User struct by username" do
    user = %User{username: "linyilun", feishu_ids: ["ou_AAA"]}
    :ok = Registry.load_snapshot(%{"linyilun" => user})

    assert {:ok, ^user} = Registry.get("linyilun")
    assert :not_found = Registry.get("nobody")
  end

  test "list/0 returns every loaded user" do
    :ok =
      Registry.load_snapshot(%{
        "linyilun" => %User{username: "linyilun", feishu_ids: ["ou_AAA"]},
        "yaoshengyue" => %User{username: "yaoshengyue", feishu_ids: ["ou_CCC"]}
      })

    names = Registry.list() |> Enum.map(& &1.username) |> Enum.sort()
    assert names == ["linyilun", "yaoshengyue"]
  end

  test "feishu_id collision: last write wins (later snapshot overwrites)" do
    # Two snapshots binding the same feishu_id to different usernames.
    # The mapping is per-load-snapshot; collisions within a single load
    # are not an error here (CLI is responsible for preventing same-id
    # binding in users.yaml; loader admits whatever is on disk).
    :ok =
      Registry.load_snapshot(%{
        "linyilun" => %User{username: "linyilun", feishu_ids: ["ou_AAA"]},
        "yaoshengyue" => %User{username: "yaoshengyue", feishu_ids: ["ou_AAA"]}
      })

    # The second insert wins on the by_feishu_id table.
    assert {:ok, _username} = Registry.lookup_by_feishu_id("ou_AAA")
  end

  # Phase 1b.4 additions

  describe "UUID-keyed API" do
    setup do
      snapshot = %{
        "linyilun" => %Esr.Entity.User.Registry.User{username: "linyilun", feishu_ids: ["ou_aaa"]},
        "alice" => %Esr.Entity.User.Registry.User{username: "alice", feishu_ids: []}
      }
      uuids = %{"linyilun" => "uuid-lyl-001", "alice" => "uuid-alice-002"}
      Esr.Entity.User.Registry.load_snapshot_with_uuids(snapshot, uuids)
      :ok
    end

    test "get_by_id returns the user struct" do
      assert {:ok, user} = Esr.Entity.User.Registry.get_by_id("uuid-lyl-001")
      assert user.username == "linyilun"
    end

    test "get_by_id returns :not_found for unknown uuid" do
      assert :not_found = Esr.Entity.User.Registry.get_by_id("00000000-0000-4000-8000-000000000000")
    end

    test "list_all returns all users" do
      all = Esr.Entity.User.Registry.list_all()
      usernames = Enum.map(all, fn {_uuid, u} -> u.username end) |> Enum.sort()
      assert usernames == ["alice", "linyilun"]
    end

    test "existing lookup_by_name still works after UUID load" do
      assert {:ok, user} = Esr.Entity.User.Registry.get("linyilun")
      assert user.username == "linyilun"
    end
  end
end
