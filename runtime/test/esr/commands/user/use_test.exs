defmodule Esr.Commands.User.UseTest do
  use ExUnit.Case, async: false

  alias Esr.Commands.User.Use, as: UserUse
  alias Esr.Entity.User.Registry, as: UserRegistry
  alias Esr.Resource.Workspace.Registry, as: WsRegistry
  alias Esr.Test.WorkspaceFixture

  setup do
    UserRegistry.load_snapshot_with_uuids(
      %{
        "alice" => %UserRegistry.User{username: "alice", feishu_ids: ["ou_a"]}
      },
      %{"alice" => "alice-uuid-1"}
    )

    on_exit(fn -> WorkspaceFixture.reset!() end)
    :ok
  end

  test "binds workspace by name to the submitting user's default" do
    ws = WorkspaceFixture.build(name: "alice-ws", owner: "alice")
    :ok = WsRegistry.put(ws)

    cmd = %{
      "submitted_by" => "ou_a",
      "args" => %{"workspace" => "alice-ws"},
      "submitter_username" => "alice"
    }

    assert {:ok, %{"action" => "user_default_set", "workspace" => "alice-ws"}} =
             UserUse.execute(cmd)

    ws_id = ws.id
    assert {:ok, ^ws_id} = UserRegistry.get_default_workspace("alice")
  end

  test "unknown workspace → unknown_workspace error" do
    cmd = %{
      "submitted_by" => "ou_a",
      "args" => %{"workspace" => "ghost-ws"},
      "submitter_username" => "alice"
    }

    assert {:error, %{"type" => "unknown_workspace"}} = UserUse.execute(cmd)
  end

  test "missing workspace arg → invalid_args" do
    cmd = %{"submitted_by" => "ou_a", "args" => %{}, "submitter_username" => "alice"}
    assert {:error, %{"type" => "invalid_args"}} = UserUse.execute(cmd)
  end

  test "unresolvable submitter → unknown_user" do
    ws = WorkspaceFixture.build(name: "alice-ws", owner: "alice")
    :ok = WsRegistry.put(ws)

    cmd = %{
      "submitted_by" => "ou_unknown",
      "args" => %{"workspace" => "alice-ws"}
      # no submitter_username — caller couldn't resolve it
    }

    assert {:error, %{"type" => "unknown_user"}} = UserUse.execute(cmd)
  end

  describe "user.json persistence (yellow-fix #1)" do
    alias Esr.Commands.User.Add, as: UserAdd
    alias Esr.Entity.User.NameIndex

    setup do
      case :ets.info(:esr_user_name_index_name_to_id) do
        :undefined -> start_supervised!({NameIndex, []})
        _ -> :ok
      end

      :ets.delete_all_objects(:esr_user_name_index_name_to_id)
      :ets.delete_all_objects(:esr_user_name_index_id_to_name)

      tmp_dir = System.tmp_dir!() |> Path.join("esr_use_persist_#{:rand.uniform(999_999)}")
      File.mkdir_p!(tmp_dir)
      System.put_env("ESRD_HOME", tmp_dir)
      System.put_env("ESR_INSTANCE", "default")
      File.mkdir_p!(Path.join(tmp_dir, "default"))

      on_exit(fn ->
        File.rm_rf!(tmp_dir)
        System.delete_env("ESRD_HOME")
        System.delete_env("ESR_INSTANCE")
        WorkspaceFixture.reset!()
      end)

      :ok
    end

    test "/user:use writes new default_workspace_id to user.json (survives restart)" do
      bob = "yellowuse-bob-#{:rand.uniform(9999)}"
      assert {:ok, %{"id" => uuid}} = UserAdd.execute(%{"args" => %{"name" => bob}})

      json_path = Path.join([Esr.Paths.users_dir(), uuid, "user.json"])
      assert File.exists?(json_path)

      original = json_path |> File.read!() |> Jason.decode!()
      original_ws_id = original["default_workspace_id"]
      assert is_binary(original_ws_id)

      ws2 = WorkspaceFixture.build(name: "#{bob}-secondary", owner: bob)
      :ok = WsRegistry.put(ws2)

      cmd = %{
        "args" => %{"workspace" => "#{bob}-secondary"},
        "submitter_username" => bob
      }

      assert {:ok, %{"workspace_id" => new_ws_id}} = UserUse.execute(cmd)
      assert new_ws_id != original_ws_id

      updated = json_path |> File.read!() |> Jason.decode!()
      assert updated["default_workspace_id"] == new_ws_id
      assert updated["id"] == uuid
      assert updated["username"] == bob
    end
  end
end
