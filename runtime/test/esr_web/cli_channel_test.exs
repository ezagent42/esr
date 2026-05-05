defmodule EsrWeb.CliChannelTest do
  @moduledoc """
  Tests for EsrWeb.CliChannel — the legacy `cli:*` Phoenix.Channel
  RPC path. Most former handlers have migrated to slash commands
  (see `runtime/priv/slash-routes.default.yaml` and
  `Esr.Commands.*`); see `docs/notes/2026-05-05-cli-channel-migration.md`
  for the full migration scope.

  Remaining live dispatches:
    - `cli:actors/list`     — read-only actor registry
    - `cli:daemon/doctor`   — runtime health snapshot
    - `cli:workspace/register` — workspace registration round-trip
                                 (slated for migration in step 9)
  """

  use ExUnit.Case, async: true

  import Phoenix.ChannelTest

  @endpoint EsrWeb.Endpoint

  setup do
    {:ok, _, socket} =
      EsrWeb.HandlerSocket
      |> socket("cli-test", %{})
      |> subscribe_and_join(EsrWeb.CliChannel, "cli:probe")

    %{socket: socket}
  end

  test "joins on cli:* topic", %{socket: socket} do
    assert socket.topic == "cli:probe"
  end

  test "unknown cli:* topic returns structured error (reviewer C2)",
       %{socket: socket} do
    ref = push(socket, "cli_call", %{"hello" => "world"})
    assert_reply ref, :ok, response
    assert response["data"]["error"] == "unknown_topic: cli:probe"
  end

  test "unknown event returns :error reply", %{socket: socket} do
    ref = push(socket, "something_else", %{})
    assert_reply ref, :error, reason
    assert reason.reason =~ "unhandled"
  end

  describe "cli:actors/list" do
    setup do
      {:ok, _, socket} =
        EsrWeb.HandlerSocket
        |> socket("cli-test-actors", %{})
        |> subscribe_and_join(EsrWeb.CliChannel, "cli:actors/list")

      %{actors_socket: socket}
    end

    test "cli_call returns the peer registry contents", %{actors_socket: socket} do
      ref = push(socket, "cli_call", %{})
      assert_reply ref, :ok, response
      assert is_list(response["data"])

      for entry <- response["data"] do
        assert is_map(entry)
        assert Map.has_key?(entry, "actor_id")
        assert Map.has_key?(entry, "pid")
      end
    end
  end

  describe "cli:workspace/register" do
    alias Esr.Resource.Workspace.Registry, as: WS

    setup do
      for {name, _} <- :ets.tab2list(:esr_workspaces), do: :ets.delete(:esr_workspaces, name)

      on_exit(fn ->
        for {name, _} <- :ets.tab2list(:esr_workspaces), do: :ets.delete(:esr_workspaces, name)
      end)

      {:ok, _, socket} =
        EsrWeb.HandlerSocket
        |> socket("cli-test-ws-register", %{})
        |> subscribe_and_join(EsrWeb.CliChannel, "cli:workspace/register")

      %{register_socket: socket}
    end

    test "round-trips metadata + neighbors (PR-F)", %{register_socket: socket} do
      payload = %{
        "name" => "ws_round_trip",
        "role" => "dev",
        "chats" => [%{"chat_id" => "oc_rt", "app_id" => "cli_rt"}],
        "neighbors" => ["workspace:ws_other"],
        "metadata" => %{"purpose" => "round-trip test"}
      }

      ref = push(socket, "cli_call", payload)
      assert_reply ref, :ok, response
      assert response["data"]["ok"] == true

      {:ok, ws} = WS.get("ws_round_trip")
      assert ws.metadata == %{"purpose" => "round-trip test"}
      assert ws.neighbors == ["workspace:ws_other"]
    end
  end
end
