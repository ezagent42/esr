defmodule Esr.Commands.Workspace.ResolveTest do
  use ExUnit.Case, async: false

  alias Esr.Commands.Workspace.Resolve
  alias Esr.Session.ChatRouting.Registry, as: ChatScope
  alias Esr.Resource.Workspace.Registry, as: WsRegistry
  alias Esr.Test.WorkspaceFixture

  setup do
    Esr.Test.UserFixture.load_snapshot(
      %{
        "alice" => %Esr.Entity.User.Struct{username: "alice", feishu_ids: ["ou_a"]}
      },
      %{"alice" => "alice-uuid"}
    )

    on_exit(fn -> WorkspaceFixture.reset!() end)
    :ok
  end

  describe "resolve_workspace_for_args/1 — fallback chain" do
    test "explicit args.workspace wins" do
      ws = WorkspaceFixture.build(name: "explicit-ws", owner: "alice")
      :ok = WsRegistry.put(ws)

      args = %{"workspace" => "explicit-ws", "submitter_username" => "alice"}
      assert {:explicit, "explicit-ws"} = Resolve.resolve_workspace_for_args(args)
    end

    test "chat-default wins over user-default" do
      ws_chat = WorkspaceFixture.build(name: "chat-ws", owner: "alice")
      :ok = WsRegistry.put(ws_chat)

      ws_user = WorkspaceFixture.build(name: "user-ws", owner: "alice")
      :ok = WsRegistry.put(ws_user)

      :ok = ChatScope.set_default_workspace("oc_x", "cli_a", ws_chat.id)
      :ok = Esr.Uri.Compat.set_default_workspace_for_user_name("alice", ws_user.id)

      args = %{
        "chat_id" => "oc_x",
        "app_id" => "cli_a",
        "submitter_username" => "alice"
      }

      assert {:chat_default, "chat-ws"} = Resolve.resolve_workspace_for_args(args)
    end

    test "user-default fires when no explicit + no chat-default" do
      ws_user = WorkspaceFixture.build(name: "user-ws", owner: "alice")
      :ok = WsRegistry.put(ws_user)
      :ok = Esr.Uri.Compat.set_default_workspace_for_user_name("alice", ws_user.id)

      args = %{"submitter_username" => "alice"}
      assert {:user_default, "user-ws"} = Resolve.resolve_workspace_for_args(args)
    end

    test "no_match when nothing in any layer" do
      args = %{"submitter_username" => "alice"}
      assert :no_match = Resolve.resolve_workspace_for_args(args)
    end

    test "submitter_username resolved via lookup_by_feishu_id when only submitted_by present" do
      ws_user = WorkspaceFixture.build(name: "alice-ws", owner: "alice")
      :ok = WsRegistry.put(ws_user)
      :ok = Esr.Uri.Compat.set_default_workspace_for_user_name("alice", ws_user.id)

      args = %{"submitted_by" => "ou_a"}
      assert {:user_default, "alice-ws"} = Resolve.resolve_workspace_for_args(args)
    end
  end
end
