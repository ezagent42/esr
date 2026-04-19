defmodule EsrWeb.CliChannelTest do
  @moduledoc """
  Tests for EsrWeb.CliChannel — Phase 8c Elixir side of the CLI → runtime
  RPC path. Joins on ``cli:*`` topics, handles ``cli_call`` events with
  a synchronous reply.
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

  test "cli_call echoes payload in the reply", %{socket: socket} do
    ref = push(socket, "cli_call", %{"hello" => "world"})
    assert_reply ref, :ok, response
    assert response == %{"echoed" => %{"hello" => "world"}, "topic" => "cli:probe"}
  end

  test "unknown event returns :error reply", %{socket: socket} do
    ref = push(socket, "something_else", %{})
    assert_reply ref, :error, reason
    assert reason.reason =~ "unhandled"
  end
end
