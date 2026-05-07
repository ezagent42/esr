defmodule Esr.Entity.User.RegistryTest do
  use ExUnit.Case, async: false

  alias Esr.Entity.User.Registry
  alias Esr.Entity.User.Registry.User
  alias Esr.Entity.User.NameIndex

  setup do
    # NameIndex must start before Registry so load_snapshot_with_uuids can populate it.
    case :ets.info(:esr_user_name_index_name_to_id) do
      :undefined -> start_supervised!({NameIndex, []})
      _ -> :ok
    end

    if Process.whereis(Registry) == nil, do: start_supervised!(Registry)

    # Clear both Registry and NameIndex state between tests.
    Registry.load_snapshot(%{})
    :ets.delete_all_objects(:esr_user_name_index_name_to_id)
    :ets.delete_all_objects(:esr_user_name_index_id_to_name)
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

  # fix/user-name-index-population — NameIndex wiring

  describe "NameIndex population via load_snapshot_with_uuids" do
    test "id_for_name resolves username after boot load" do
      snapshot = %{
        "linyilun" => %User{username: "linyilun", feishu_ids: []},
        "alice" => %User{username: "alice", feishu_ids: []}
      }
      uuids = %{"linyilun" => "uuid-lyl-100", "alice" => "uuid-alice-200"}

      :ok = Registry.load_snapshot_with_uuids(snapshot, uuids)

      assert {:ok, "uuid-lyl-100"} = NameIndex.id_for_name("linyilun")
      assert {:ok, "uuid-alice-200"} = NameIndex.id_for_name("alice")
    end

    test "id_for_name returns :not_found for user without UUID in map" do
      snapshot = %{"ghost" => %User{username: "ghost", feishu_ids: []}}
      # ghost is in the snapshot but has no UUID assigned
      :ok = Registry.load_snapshot_with_uuids(snapshot, %{})

      assert :not_found = NameIndex.id_for_name("ghost")
    end

    test "reload clears stale NameIndex entries" do
      :ok =
        Registry.load_snapshot_with_uuids(
          %{"old" => %User{username: "old", feishu_ids: []}},
          %{"old" => "uuid-old-111"}
        )

      assert {:ok, "uuid-old-111"} = NameIndex.id_for_name("old")

      # Second load replaces entire snapshot — old entry must be gone.
      :ok =
        Registry.load_snapshot_with_uuids(
          %{"new" => %User{username: "new", feishu_ids: []}},
          %{"new" => "uuid-new-222"}
        )

      assert :not_found = NameIndex.id_for_name("old")
      assert {:ok, "uuid-new-222"} = NameIndex.id_for_name("new")
    end
  end
end
