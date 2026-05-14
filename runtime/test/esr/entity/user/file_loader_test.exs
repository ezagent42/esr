defmodule Esr.Entity.User.FileLoaderTest do
  @moduledoc """
  PR-1 (2026-05-12 URI identity migration): FileLoader now populates
  the URI store (`:esr_uri_store`), not the deleted Registry. These
  tests assert via `Esr.Uri.Compat.*` wrappers, which read straight
  from the URI store.
  """

  use ExUnit.Case, async: false

  alias Esr.Entity.User.FileLoader

  setup do
    # URI store must be running for FileLoader to populate. The
    # Application supervisor normally starts it; reuse the running one
    # or start a fresh instance if absent.
    case Process.whereis(Esr.Uri.Store) do
      nil -> start_supervised!(Esr.Uri.Store)
      _ -> :ok
    end

    # Clear any leftover :user entries (and their aliases) between tests.
    Esr.Uri.Store.delete_all_by_kind(:user)

    tmp_dir = System.tmp_dir!() |> Path.join("esr-users-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  defp write_user_json(tmp_dir, uuid, username, feishu_ids, default_workspace_id \\ nil) do
    dir = Path.join([tmp_dir, "users", uuid])
    File.mkdir_p!(dir)

    doc = %{
      "schema_version" => 1,
      "id" => uuid,
      "username" => username,
      "feishu_ids" => feishu_ids,
      "default_workspace_id" => default_workspace_id
    }

    File.write!(Path.join(dir, "user.json"), Jason.encode!(doc))
  end

  test "load valid file populates URI store via Compat", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "users.yaml")

    write_user_json(tmp_dir, "uuid-linyilun", "linyilun", ["ou_AAA", "ou_BBB"])
    write_user_json(tmp_dir, "uuid-yao", "yaoshengyue", ["ou_CCC"])

    File.write!(path, """
    users:
      linyilun:
        feishu_ids:
          - ou_AAA
          - ou_BBB
      yaoshengyue:
        feishu_ids:
          - ou_CCC
    """)

    assert :ok = FileLoader.load(path)
    assert {:ok, "linyilun"} = Esr.Uri.Compat.username_for_feishu_id("ou_AAA")
    assert {:ok, "linyilun"} = Esr.Uri.Compat.username_for_feishu_id("ou_BBB")
    assert {:ok, "yaoshengyue"} = Esr.Uri.Compat.username_for_feishu_id("ou_CCC")
    assert length(Esr.Uri.Compat.list_users()) == 2
  end

  test "missing file → empty URI store, no error" do
    assert :ok =
             FileLoader.load("/tmp/does-not-exist-#{System.unique_integer([:positive])}.yaml")

    assert Esr.Uri.Compat.list_users() == []
  end

  test "malformed yaml → error, prior URI store kept", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "users.yaml")

    write_user_json(tmp_dir, "uuid-linyilun", "linyilun", ["ou_AAA"])

    File.write!(path, """
    users:
      linyilun:
        feishu_ids:
          - ou_AAA
    """)

    :ok = FileLoader.load(path)
    assert {:ok, "linyilun"} = Esr.Uri.Compat.username_for_feishu_id("ou_AAA")

    File.write!(path, "users:\n  - this is not a map\n  unbalanced: [")
    assert {:error, {:yaml_parse, _}} = FileLoader.load(path)

    # Prior URI store rows survive
    assert {:ok, "linyilun"} = Esr.Uri.Compat.username_for_feishu_id("ou_AAA")
  end

  test "user with no feishu_ids is admitted with empty list", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "users.yaml")

    write_user_json(tmp_dir, "uuid-orphan", "orphan", [])
    write_user_json(tmp_dir, "uuid-ghost", "ghost", [])

    File.write!(path, """
    users:
      orphan:
        feishu_ids: []
      ghost: {}
    """)

    assert :ok = FileLoader.load(path)
    assert {:ok, %{feishu_ids: []}} = Esr.Uri.Compat.user_by_name("orphan")
    assert {:ok, %{feishu_ids: []}} = Esr.Uri.Compat.user_by_name("ghost")
  end

  test "non-conforming username admitted with warning", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "users.yaml")

    write_user_json(tmp_dir, "uuid-spaces", "user with spaces", ["ou_X"])

    File.write!(path, """
    users:
      "user with spaces":
        feishu_ids: [ou_X]
    """)

    # Logger is captured implicitly; we just assert the load succeeds and
    # the user is queryable. Operators editing the file by hand shouldn't
    # see a hard reject.
    assert :ok = FileLoader.load(path)
    assert {:ok, _} = Esr.Uri.Compat.user_by_name("user with spaces")
  end

  describe "default_workspace_id round-trip via user.json (M-5/D2)" do
    test "FileLoader populates User.default_workspace_id when set in user.json", %{
      tmp_dir: tmp_dir
    } do
      write_user_json(tmp_dir, "uuid-alice", "alice", ["ou_a"], "ws-uuid-7")

      yaml_path = Path.join(tmp_dir, "users.yaml")
      # No yaml file — loader falls through to load_from_users_dir
      assert :ok = FileLoader.load(yaml_path)

      assert {:ok, %{default_workspace_id: "ws-uuid-7"}} =
               Esr.Uri.Compat.user_by_name("alice")
    end

    test "default_workspace_id stays nil when absent from user.json", %{tmp_dir: tmp_dir} do
      write_user_json(tmp_dir, "uuid-alice", "alice", ["ou_a"], nil)

      yaml_path = Path.join(tmp_dir, "users.yaml")
      assert :ok = FileLoader.load(yaml_path)

      assert {:ok, %{default_workspace_id: nil}} =
               Esr.Uri.Compat.user_by_name("alice")
    end
  end

  describe "auto-mint UUID for yaml entries missing user.json (closes PR-356 silent-skip)" do
    test "yaml entry with no matching user.json gets a UUID minted + persisted",
         %{tmp_dir: tmp_dir} do
      # Setup: users.yaml has 'fixture_user', no users/<uuid>/user.json on disk.
      # This is the e2e fixture seed path (and the legacy hand-edit path).
      path = Path.join(tmp_dir, "users.yaml")

      File.write!(path, """
      users:
        fixture_user:
          feishu_ids:
            - ou_fixture_seed
      """)

      assert :ok = FileLoader.load(path)

      # URI store is populated: feishu alias resolves to canonical user.
      assert {:ok, "fixture_user"} =
               Esr.Uri.Compat.username_for_feishu_id("ou_fixture_seed")

      assert {:ok, %{username: "fixture_user", feishu_ids: ["ou_fixture_seed"]}} =
               Esr.Uri.Compat.user_by_name("fixture_user")

      # And the user.json was actually written to disk.
      users_dir = Path.join(tmp_dir, "users")
      [uuid_dir] = File.ls!(users_dir)
      json_path = Path.join([users_dir, uuid_dir, "user.json"])
      assert File.exists?(json_path)

      doc = json_path |> File.read!() |> Jason.decode!()
      assert doc["username"] == "fixture_user"
      assert doc["id"] == uuid_dir
      assert doc["feishu_ids"] == ["ou_fixture_seed"]
      assert doc["schema_version"] == 1
    end

    test "auto-mint is idempotent across reloads (no UUID churn)",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "users.yaml")

      File.write!(path, """
      users:
        stable_user:
          feishu_ids: []
      """)

      assert :ok = FileLoader.load(path)

      users_dir = Path.join(tmp_dir, "users")
      uuid_first_load = File.ls!(users_dir) |> hd()

      assert :ok = FileLoader.load(path)

      # Same UUID dir; second load reads it from disk instead of minting again.
      assert File.ls!(users_dir) == [uuid_first_load]
    end

    test "mixed yaml: some entries have user.json, others get auto-minted",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "users.yaml")

      # 'alice' already has a UUID dir; 'bob' is yaml-only.
      write_user_json(tmp_dir, "uuid-alice-preexisting", "alice", ["ou_A"])

      File.write!(path, """
      users:
        alice:
          feishu_ids:
            - ou_A
        bob:
          feishu_ids:
            - ou_B
      """)

      assert :ok = FileLoader.load(path)

      # Pre-existing UUID is preserved.
      assert {:ok, "alice"} = Esr.Uri.Compat.username_for_feishu_id("ou_A")
      users_dir = Path.join(tmp_dir, "users")
      assert "uuid-alice-preexisting" in File.ls!(users_dir)

      # Auto-minted user is also resolvable.
      assert {:ok, "bob"} = Esr.Uri.Compat.username_for_feishu_id("ou_B")
      assert {:ok, %{username: "bob"}} = Esr.Uri.Compat.user_by_name("bob")
    end
  end
end
