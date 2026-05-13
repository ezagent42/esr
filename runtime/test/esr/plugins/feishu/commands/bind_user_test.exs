defmodule Esr.Plugins.Feishu.Commands.BindUserTest do
  @moduledoc """
  Walkthrough-4 PR-A tests for `Esr.Plugins.Feishu.Commands.BindUser`:

  - C5-B: in-memory NameIndex / URI store reflects the new binding
    synchronously after the command returns (no esrd restart needed).
  - C10: `users/<uuid>/user.json`'s `feishu_ids` mirrors `users.yaml`.

  Each test sets up an isolated `ESRD_HOME` tmp dir so disk writes
  don't pollute the operator's real `.esrd/`.
  """

  use ExUnit.Case, async: false

  alias Esr.Plugins.Feishu.Commands.BindUser

  @uuid "11111111-2222-4333-8444-555555555555"

  setup do
    saved_home = System.get_env("ESRD_HOME")
    saved_inst = System.get_env("ESR_INSTANCE")

    tmp =
      Path.join(
        System.tmp_dir!(),
        "bind_user_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    System.put_env("ESRD_HOME", tmp)
    System.put_env("ESR_INSTANCE", "default")

    # Make sure the URI store is running so FileLoader.load can write.
    if Process.whereis(Esr.Uri.Store) == nil do
      start_supervised!(Esr.Uri.Store)
    end

    # Seed disk: users.yaml with linyilun (no feishu_ids yet) +
    # matching user.json so the C10 sync path can find it.
    runtime_home = Path.join([tmp, "default"])
    users_dir = Path.join([runtime_home, "users", @uuid])
    File.mkdir_p!(users_dir)

    File.write!(
      Path.join(runtime_home, "users.yaml"),
      "users:\n  linyilun:\n    feishu_ids: []\n"
    )

    File.write!(
      Path.join(users_dir, "user.json"),
      Jason.encode!(
        %{
          "schema_version" => 1,
          "id" => @uuid,
          "username" => "linyilun",
          "display_name" => "",
          "feishu_ids" => [],
          "default_workspace_id" => nil,
          "created_at" => "2026-05-13T00:00:00Z"
        },
        pretty: true
      )
    )

    # Load the URI store from disk so subsequent `Compat.*` calls
    # find linyilun.
    Esr.Entity.User.FileLoader.load(Path.join(runtime_home, "users.yaml"))

    on_exit(fn ->
      File.rm_rf!(tmp)

      if saved_home,
        do: System.put_env("ESRD_HOME", saved_home),
        else: System.delete_env("ESRD_HOME")

      if saved_inst,
        do: System.put_env("ESR_INSTANCE", saved_inst),
        else: System.delete_env("ESR_INSTANCE")

      # Reset the URI store between tests
      Esr.Uri.Store.delete_all_by_kind(:user)
    end)

    {:ok, tmp: tmp, runtime_home: runtime_home}
  end

  describe "C5-B: in-memory NameIndex sync after bind" do
    test "feishu_bind updates URI store so lookup_by_feishu_id immediately succeeds" do
      # Pre-bind: nothing resolves to linyilun by feishu_id.
      assert :not_found = Esr.Uri.Compat.username_for_feishu_id("ou_walkthrough4")

      assert {:ok, _} =
               BindUser.execute(%{
                 "args" => %{
                   "name" => "linyilun",
                   "feishu_user_id" => "ou_walkthrough4"
                 }
               })

      # Post-bind: lookup must succeed WITHOUT esrd restart (the C5-B
      # regression we're guarding against).
      assert {:ok, "linyilun"} =
               Esr.Uri.Compat.username_for_feishu_id("ou_walkthrough4")
    end

    test "after bind, Capability.has? sees grants via the new feishu_id binding" do
      # Grant cap by UUID (auto-admin scenario).
      Esr.Resource.Capability.Grants.load_snapshot(%{@uuid => ["session:default/create"]})

      assert {:ok, _} =
               BindUser.execute(%{
                 "args" => %{
                   "name" => "linyilun",
                   "feishu_user_id" => "ou_walkthrough4"
                 }
               })

      # The ou_xxx → linyilun → UUID chain must reach the UUID-keyed cap
      # immediately after bind (C5-B + PR-B C16 combined).
      assert Esr.Resource.Capability.has?("ou_walkthrough4", "session:default/create"),
             "binding must propagate to in-mem store so cap resolution chain works"
    end
  end

  describe "C10: user.json feishu_ids mirror" do
    test "feishu_bind appends feishu_id to users/<uuid>/user.json", %{
      runtime_home: runtime_home
    } do
      json_path = Path.join([runtime_home, "users", @uuid, "user.json"])

      pre = Jason.decode!(File.read!(json_path))
      assert pre["feishu_ids"] == [], "test fixture must start with empty feishu_ids"

      assert {:ok, _} =
               BindUser.execute(%{
                 "args" => %{
                   "name" => "linyilun",
                   "feishu_user_id" => "ou_walkthrough4"
                 }
               })

      post = Jason.decode!(File.read!(json_path))

      assert post["feishu_ids"] == ["ou_walkthrough4"],
             "user.json feishu_ids must mirror users.yaml after bind (C10)"
    end

    test "rebinding the same feishu_id is idempotent on user.json", %{
      runtime_home: runtime_home
    } do
      json_path = Path.join([runtime_home, "users", @uuid, "user.json"])

      assert {:ok, _} =
               BindUser.execute(%{
                 "args" => %{"name" => "linyilun", "feishu_user_id" => "ou_idem"}
               })

      # Second bind on already-bound feishu_id is a no-op at the yaml
      # level (returns `already bound to ...`). user.json should not
      # gain a duplicate either.
      assert {:ok, _} =
               BindUser.execute(%{
                 "args" => %{"name" => "linyilun", "feishu_user_id" => "ou_idem"}
               })

      post = Jason.decode!(File.read!(json_path))
      assert post["feishu_ids"] == ["ou_idem"], "no duplicate feishu_id on rebind"
    end
  end
end
