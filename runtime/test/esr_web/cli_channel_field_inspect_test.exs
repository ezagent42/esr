defmodule EsrWeb.CliChannelFieldInspectTest do
  @moduledoc """
  Regression coverage for the actor field-drill behavior previously
  hosted at `EsrWeb.CliChannel.dispatch("cli:actors/inspect", ...)`.
  Post-2026-05-05 cli-channel→slash migration the home is
  `Esr.Commands.Actors.Inspect`; this test now exercises that
  module's `execute/1` directly with the slash-arg envelope shape.
  """
  use ExUnit.Case, async: false

  alias Esr.Commands.Actors.Inspect, as: ActorsInspect

  setup do
    actor_id = "test_actor_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Esr.Entity.Server.start_link(
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

  test "execute returns value at dotted field path", %{actor_id: aid} do
    assert {:ok, %{"text" => text}} =
             ActorsInspect.execute(%{
               "args" => %{"actor_id" => aid, "field" => "state.session_name"}
             })

    assert text =~ "field=state.session_name"
    assert text =~ "esr_cc_42"
  end

  test "missing field path returns structured error", %{actor_id: aid} do
    assert {:error, %{"type" => "field_not_present", "message" => msg}} =
             ActorsInspect.execute(%{
               "args" => %{"actor_id" => aid, "field" => "state.does_not_exist"}
             })

    assert msg =~ "state.does_not_exist"
  end
end
