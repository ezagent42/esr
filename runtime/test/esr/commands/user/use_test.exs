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
end
