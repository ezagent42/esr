defmodule EsrWeb.CliChannelTest do
  @moduledoc """
  Tests for `EsrWeb.CliChannel` — the legacy `cli:*` Phoenix.Channel
  RPC path. All former dispatch handlers have been migrated to slash
  commands (see `runtime/priv/slash-routes.default.yaml` +
  `Esr.Commands.*`); the channel remains as a thin protocol shell
  that returns `unknown_topic` for every topic. Will be deleted with
  the Python CLI in step 12 of the migration
  (`docs/notes/2026-05-05-cli-channel-migration.md`).
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

  test "every cli_call now returns unknown_topic (handlers migrated)",
       %{socket: socket} do
    ref = push(socket, "cli_call", %{"hello" => "world"})
    assert_reply ref, :ok, response
    assert response["data"]["error"] == "unknown_topic: cli:probe"
  end

  test "non-cli:* topic is rejected at join" do
    assert {:error, %{reason: "invalid topic"}} =
             EsrWeb.HandlerSocket
             |> socket("cli-bad", %{})
             |> subscribe_and_join(EsrWeb.CliChannel, "not_cli:bad")
  end

  test "unknown event returns :error reply", %{socket: socket} do
    ref = push(socket, "something_else", %{})
    assert_reply ref, :error, reason
    assert reason.reason =~ "unhandled"
  end
end
