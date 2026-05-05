defmodule Esr.Commands.DebugTest do
  @moduledoc """
  Unit coverage for `Esr.Commands.Debug.{Pause,Resume}`. These wrap
  `Esr.Entity.Server.{pause,resume}/1` (which toggle the actor's
  `paused` field; messages queue up until resume drains them).

  The yaml `e2e-feishu-cc.yaml` Track-G previously exercised these
  via `esr debug pause/resume` against a live actor. That scenario
  is deleted in this PR — these tests are the replacement coverage.
  """
  use ExUnit.Case, async: false

  alias Esr.Commands.Debug

  setup do
    actor_id = "test_actor_debug_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Esr.Entity.Server.start_link(
        actor_id: actor_id,
        actor_type: "test",
        handler_module: "noop",
        initial_state: %{}
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

  describe "Debug.Pause.execute/1" do
    test "live actor → flips paused=true and reports", %{actor_id: aid} do
      assert {:ok, %{"text" => text}} =
               Debug.Pause.execute(%{"args" => %{"actor_id" => aid}})

      assert text =~ aid
      assert text =~ "paused=true"
      assert Esr.Entity.Server.describe(aid).paused == true
    end

    test "missing actor → actor_not_found error" do
      assert {:error, %{"type" => "actor_not_found", "message" => msg}} =
               Debug.Pause.execute(%{"args" => %{"actor_id" => "ghost:nope"}})

      assert msg =~ "ghost:nope"
    end

    test "missing args → invalid_args error" do
      assert {:error, %{"type" => "invalid_args"}} =
               Debug.Pause.execute(%{"args" => %{}})
    end
  end

  describe "Debug.Resume.execute/1" do
    test "live + paused actor → flips paused=false", %{actor_id: aid} do
      :ok = Esr.Entity.Server.pause(aid)
      assert Esr.Entity.Server.describe(aid).paused == true

      assert {:ok, %{"text" => text}} =
               Debug.Resume.execute(%{"args" => %{"actor_id" => aid}})

      assert text =~ aid
      assert text =~ "paused=false"
      assert Esr.Entity.Server.describe(aid).paused == false
    end

    test "missing actor → actor_not_found error" do
      assert {:error, %{"type" => "actor_not_found"}} =
               Debug.Resume.execute(%{"args" => %{"actor_id" => "ghost:nope"}})
    end

    test "missing args → invalid_args error" do
      assert {:error, %{"type" => "invalid_args"}} =
               Debug.Resume.execute(%{"args" => %{}})
    end
  end
end
