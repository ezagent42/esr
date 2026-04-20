defmodule Esr.Topology.WorkspaceValidationTest do
  use ExUnit.Case, async: false

  alias Esr.Topology.Instantiator
  alias Esr.Workspaces.Registry, as: WsReg

  setup do
    # Ensure no prior test left a stray feishu-app adapter bound to
    # "cli_unregistered" — HubRegistry persists across tests in :set mode.
    :ok
  end

  test "instantiate rejects when workspace app_id is not in adapter registry" do
    ws = %WsReg.Workspace{
      name: "esr-dev-#{System.unique_integer([:positive])}",
      cwd: "/tmp",
      start_cmd: "scripts/esr-cc.sh",
      role: "dev",
      chats: [
        %{"chat_id" => "oc_x", "app_id" => "cli_unregistered_#{System.unique_integer([:positive])}", "kind" => "dm"}
      ],
      env: %{}
    }

    :ok = WsReg.put(ws)

    artifact = %{
      "name" => "feishu-thread-session",
      "params" => ["thread_id", "chat_id", "workspace", "tag"],
      "nodes" => [],
      "edges" => []
    }

    [%{"app_id" => missing_app}] = ws.chats

    assert {:error, {:app_not_registered, ^missing_app}} =
             Instantiator.instantiate(artifact, %{
               "thread_id" => "t",
               "chat_id" => "oc_x",
               "workspace" => ws.name,
               "tag" => "t"
             })
  end

  test "instantiate skips validation when workspace param is absent" do
    artifact = %{
      "name" => "feishu-thread-session-#{System.unique_integer([:positive])}",
      "params" => ["thread_id", "chat_id"],
      "nodes" => [],
      "edges" => []
    }

    # No workspace param → should NOT error on app validation.
    # Spawn chain for empty nodes succeeds trivially.
    assert {:ok, _} =
             Instantiator.instantiate(artifact, %{
               "thread_id" => "t",
               "chat_id" => "oc_x"
             })
  end
end
