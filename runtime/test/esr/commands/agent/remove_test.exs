defmodule Esr.Commands.Agent.RemoveTest do
  use ExUnit.Case, async: false
  alias Esr.Commands.Agent.Remove

  setup do
    case Process.whereis(Esr.Entity.Agent.InstanceRegistry) do
      nil -> start_supervised!(Esr.Entity.Agent.InstanceRegistry)
      _ -> :ok
    end

    :ok
  end

  test "missing args: returns invalid_args" do
    assert {:error, %{"type" => "invalid_args"}} =
             Remove.execute(%{"args" => %{}})
  end

  test "name not present in session: returns not_found" do
    sid = "55555555-5555-4555-8555-555555555555"
    cmd = %{"args" => %{"session_id" => sid, "name" => "ghost"}}
    assert {:error, %{"type" => "not_found"}} = Remove.execute(cmd)
  end
end
