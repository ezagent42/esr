defmodule Esr.Resource.Workspace.RegistryTest do
  use ExUnit.Case, async: false

  alias Esr.Resource.Workspace.Registry
  alias Esr.Test.WorkspaceFixture

  describe "workspace_for_chat/2 (PR-9 T11b.1)" do
    setup do
      assert is_pid(Process.whereis(Registry))

      cleanup = fn ->
        for name <- ["ws_alpha", "ws_beta", "ws_empty"] do
          WorkspaceFixture.delete!(name)
        end
      end

      cleanup.()
      on_exit(cleanup)

      :ok
    end

    test "returns {:ok, name} when an exact (chat_id, app_id) pair matches" do
      :ok =
        Registry.put(
          WorkspaceFixture.build(
            name: "ws_alpha",
            owner: "linyilun",
            role: "dev",
            chats: [
              %{"chat_id" => "oc_a", "app_id" => "cli_x", "kind" => "dm"},
              %{"chat_id" => "oc_b", "app_id" => "cli_x", "kind" => "group"}
            ]
          )
        )

      assert Registry.workspace_for_chat("oc_a", "cli_x") == {:ok, "ws_alpha"}
      assert Registry.workspace_for_chat("oc_b", "cli_x") == {:ok, "ws_alpha"}
    end

    test "mismatched app_id returns :not_found even when chat_id matches" do
      :ok =
        Registry.put(
          WorkspaceFixture.build(
            name: "ws_alpha",
            owner: "linyilun",
            role: "dev",
            chats: [%{"chat_id" => "oc_a", "app_id" => "cli_x", "kind" => "dm"}]
          )
        )

      assert Registry.workspace_for_chat("oc_a", "cli_other") == :not_found
    end

    test "scans across workspaces (first match wins) + no-match returns :not_found" do
      :ok =
        Registry.put(
          WorkspaceFixture.build(
            name: "ws_alpha",
            owner: "linyilun",
            role: "dev",
            chats: [%{"chat_id" => "oc_a", "app_id" => "cli_x", "kind" => "dm"}]
          )
        )

      :ok =
        Registry.put(
          WorkspaceFixture.build(
            name: "ws_beta",
            owner: "linyilun",
            role: "dev",
            chats: [%{"chat_id" => "oc_c", "app_id" => "cli_y", "kind" => "group"}]
          )
        )

      :ok =
        Registry.put(
          WorkspaceFixture.build(
            name: "ws_empty",
            owner: "linyilun",
            role: "dev"
          )
        )

      assert Registry.workspace_for_chat("oc_c", "cli_y") == {:ok, "ws_beta"}
      assert Registry.workspace_for_chat("oc_missing", "cli_x") == :not_found
    end
  end
end
