defmodule EsrWeb.CliChannelFieldInspectTest do
  @moduledoc """
  Task H — cli:actors/inspect accepts {arg, field} and returns the
  value at the dotted field path from the peer's describe map.
  """
  use ExUnit.Case, async: false

  alias EsrWeb.CliChannel

  # Spin up a real PeerServer via start_link so it registers itself
  # under its actor_id in Esr.PeerRegistry and answers :describe via
  # the usual via-tuple. Manual Registry.register would map the test
  # pid instead, causing describe/1 to call itself.
  setup do
    actor_id = "test_actor_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Esr.PeerServer.start_link(
        actor_id: actor_id,
        actor_type: "test",
        handler_module: "x",
        initial_state: %{
          "session_name" => "esr_cc_42",
          "channel_adapter" => "feishu_app"
        }
      )

    on_exit(fn ->
      try do
        if Process.alive?(pid), do: GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)
    {:ok, actor_id: actor_id}
  end

  test "dispatch returns value at dotted field path", %{actor_id: aid} do
    resp =
      CliChannel.dispatch(
        "cli:actors/inspect",
        %{"arg" => aid, "field" => "state.session_name"}
      )

    assert resp["data"]["field"] == "state.session_name"
    assert resp["data"]["value"] == "esr_cc_42"
  end

  test "missing field path returns structured error", %{actor_id: aid} do
    resp =
      CliChannel.dispatch(
        "cli:actors/inspect",
        %{"arg" => aid, "field" => "state.does_not_exist"}
      )

    assert resp["data"]["error"] == "field not present"
    assert resp["data"]["field"] == "state.does_not_exist"
  end
end
