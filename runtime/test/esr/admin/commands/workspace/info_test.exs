defmodule Esr.Admin.Commands.Workspace.InfoTest do
  use ExUnit.Case, async: false

  alias Esr.Admin.Commands.Workspace.Info, as: WorkspaceInfo

  setup do
    assert is_pid(Process.whereis(Esr.Resource.Workspace.Registry))

    on_exit(fn ->
      :ets.delete(:esr_workspaces, "ws_info_test")
    end)

    :ok
  end

  test "returns the workspace record when present" do
    :ok =
      Esr.Resource.Workspace.Registry.put(%Esr.Resource.Workspace.Registry.Workspace{
        name: "ws_info_test",
        owner: "linyilun",
        role: "dev",
        start_cmd: "scripts/esr-cc.sh",
        chats: [%{"chat_id" => "oc_a", "app_id" => "cli_x", "kind" => "dm"}],
        env: %{},
        neighbors: ["workspace:other-ws"],
        metadata: %{"purpose" => "test"}
      })

    cmd = %{"submitted_by" => "ou_test", "args" => %{"workspace" => "ws_info_test"}}

    assert {:ok, info} = WorkspaceInfo.execute(cmd)
    assert info["name"] == "ws_info_test"
    assert info["owner"] == "linyilun"
    # PR-22: workspace no longer carries `root:` — repo is per-session.
    refute Map.has_key?(info, "root")
    assert info["role"] == "dev"
    assert info["chats"] == [%{"chat_id" => "oc_a", "app_id" => "cli_x", "kind" => "dm"}]
    assert info["neighbors"] == ["workspace:other-ws"]
    assert info["metadata"] == %{"purpose" => "test"}
  end

  test "unknown workspace → error" do
    cmd = %{"submitted_by" => "ou_test", "args" => %{"workspace" => "nonexistent_ws_xyz"}}
    assert {:error, %{"type" => "unknown_workspace"}} = WorkspaceInfo.execute(cmd)
  end

  test "missing args.workspace → invalid_args" do
    cmd = %{"submitted_by" => "ou_test", "args" => %{}}
    assert {:error, %{"type" => "invalid_args"}} = WorkspaceInfo.execute(cmd)
  end

  test "empty workspace string → invalid_args" do
    cmd = %{"submitted_by" => "ou_test", "args" => %{"workspace" => ""}}
    assert {:error, %{"type" => "invalid_args"}} = WorkspaceInfo.execute(cmd)
  end
end
