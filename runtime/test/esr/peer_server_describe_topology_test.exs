defmodule Esr.PeerServerDescribeTopologyTest do
  @moduledoc """
  PR-21z (2026-04-30) — security regression tests for the
  `describe_topology` MCP tool's response filter.

  `Esr.PeerServer.build_emit_for_tool("describe_topology", ...)` is
  the only response builder that returns workspace yaml data verbatim
  to the LLM. Its allowlist (`filter_workspace_for_describe/1`) is a
  **security boundary** — operators put `metadata` keys like
  `purpose`, `pipeline_position` there for the LLM to read, but
  `owner`, `start_cmd`, `env`, and `users.yaml` data must NEVER leak.

  These tests pin the response shape so adding a new field to
  `%Workspace{}` won't accidentally pass through. If a future
  contributor needs to expose a new field, the right path is:

    1. Update `filter_workspace_for_describe/1` (explicit add)
    2. Add a regression test asserting the field IS present
    3. Update this file's "must not leak" list if relevant

  See peer_server.ex `filter_workspace_for_describe/1` comment for
  the rationale on each excluded field.
  """

  use ExUnit.Case, async: false

  alias Esr.PeerServer
  alias Esr.Workspaces.Registry, as: WsReg

  # WsReg has no `delete/1` API — cleanup is by uniqueness of test
  # workspace names (the `ws_audit_*` prefix). The boot tree's
  # WsReg + Watcher persist across tests; that's fine, we only care
  # about the rows we insert here.

  defp peer_state do
    %PeerServer{
      actor_id: "test-actor",
      actor_type: "cc_process",
      handler_module: "noop",
      state: %{}
    }
  end

  test "response includes only the allowlisted workspace fields" do
    :ok =
      WsReg.put(%WsReg.Workspace{
        name: "ws_audit_1",
        owner: "linyilun",
        role: "dev",
        start_cmd: "scripts/secret-launch.sh",
        env: %{"AWS_SECRET" => "should-not-leak"},
        chats: [
          %{
            "chat_id" => "oc_1",
            "app_id" => "app_a",
            "kind" => "dm",
            "name" => "alice"
          }
        ],
        neighbors: ["workspace:ws_audit_2"],
        metadata: %{"purpose" => "ingestion", "pipeline_position" => "head"}
      })

    {:ok, :direct_ack, %{"data" => data}} =
      PeerServer.build_emit_for_tool_for_test(
        "describe_topology",
        %{"workspace_name" => "ws_audit_1"},
        peer_state()
      )

    current = data["current_workspace"]
    keys = Map.keys(current) |> Enum.sort()

    assert keys == [
             "chats",
             "metadata",
             "name",
             "neighbors_declared",
             "role"
           ]
  end

  test "owner field is filtered out (esr-username is sensitive identity material)" do
    :ok =
      WsReg.put(%WsReg.Workspace{
        name: "ws_audit_owner",
        owner: "linyilun",
        chats: []
      })

    {:ok, :direct_ack, %{"data" => data}} =
      PeerServer.build_emit_for_tool_for_test(
        "describe_topology",
        %{"workspace_name" => "ws_audit_owner"},
        peer_state()
      )

    refute Map.has_key?(data["current_workspace"], "owner")
    refute serialize(data) =~ "linyilun"
  end

  test "start_cmd / env are filtered out (operator config)" do
    :ok =
      WsReg.put(%WsReg.Workspace{
        name: "ws_audit_cmd",
        owner: "linyilun",
        start_cmd: "/usr/local/bin/launch.sh --token AKIASOMETHING",
        env: %{"PROD_API_KEY" => "do-not-leak"},
        chats: []
      })

    {:ok, :direct_ack, %{"data" => data}} =
      PeerServer.build_emit_for_tool_for_test(
        "describe_topology",
        %{"workspace_name" => "ws_audit_cmd"},
        peer_state()
      )

    refute Map.has_key?(data["current_workspace"], "start_cmd")
    refute Map.has_key?(data["current_workspace"], "env")
    refute serialize(data) =~ "AKIASOMETHING"
    refute serialize(data) =~ "PROD_API_KEY"
    refute serialize(data) =~ "do-not-leak"
  end

  test "chats sub-map is also allowlisted (no surprise nested fields)" do
    :ok =
      WsReg.put(%WsReg.Workspace{
        name: "ws_audit_chats",
        owner: "linyilun",
        chats: [
          %{
            "chat_id" => "oc_1",
            "app_id" => "app_a",
            "kind" => "dm",
            "name" => "alice",
            "metadata" => %{"label" => "primary"},
            # Hypothetical future field that mustn't leak
            "feishu_user_ids" => ["ou_should_not_leak"],
            "secret_token" => "do-not-leak-this-either"
          }
        ]
      })

    {:ok, :direct_ack, %{"data" => data}} =
      PeerServer.build_emit_for_tool_for_test(
        "describe_topology",
        %{"workspace_name" => "ws_audit_chats"},
        peer_state()
      )

    [chat] = data["current_workspace"]["chats"]
    keys = Map.keys(chat) |> Enum.sort()
    assert keys == ["app_id", "chat_id", "kind", "metadata", "name"]
    refute serialize(data) =~ "ou_should_not_leak"
    refute serialize(data) =~ "do-not-leak-this-either"
  end

  test "users.yaml data is never reachable via describe_topology" do
    # Sanity check: even if Esr.Users.Registry has bindings, the
    # describe_topology response builder doesn't read from it. This
    # test sets up users + workspaces + asserts no feishu_id appears
    # anywhere in the response payload.
    if Process.whereis(Esr.Users.Registry) do
      Esr.Users.Registry.load_snapshot(%{
        "linyilun" => %Esr.Users.Registry.User{
          username: "linyilun",
          feishu_ids: ["ou_secret_open_id_xyz"]
        }
      })
    end

    :ok =
      WsReg.put(%WsReg.Workspace{
        name: "ws_audit_users",
        owner: "linyilun",
        chats: [%{"chat_id" => "oc_1", "app_id" => "app_a", "kind" => "dm"}]
      })

    {:ok, :direct_ack, %{"data" => data}} =
      PeerServer.build_emit_for_tool_for_test(
        "describe_topology",
        %{"workspace_name" => "ws_audit_users"},
        peer_state()
      )

    refute serialize(data) =~ "ou_secret_open_id_xyz"
    refute serialize(data) =~ "feishu_id"
  end

  defp serialize(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)
end
