defmodule Esr.Commands.Pty.AttachTest do
  @moduledoc """
  `/pty:attach pty=<actor_id>` — emit a clickable URL backed by
  `EsrWeb.PtySocket`. Spec rev-4 §4.2 row `/pty:attach`. Phase E task E.2.
  """

  use ExUnit.Case, async: false
  alias Esr.Commands.Pty.Attach

  setup do
    case Process.whereis(Esr.Entity.Agent.InstanceRegistry) do
      nil -> start_supervised!(Esr.Entity.Agent.InstanceRegistry)
      _ -> :ok
    end

    case Process.whereis(Esr.Session.ChatRouting.Registry) do
      nil -> start_supervised!(Esr.Session.ChatRouting.Registry)
      _ -> :ok
    end

    :ok
  end

  test "with pty=<id>: emits a URL containing the pty actor id" do
    cmd = %{"submitted_by" => "linyilun", "args" => %{"pty" => "pty-uuid-attach"}}
    assert {:ok, %{"text" => text, "url" => url}} = Attach.execute(cmd)
    assert text =~ "pty-uuid-attach"
    assert url =~ "pty-uuid-attach"
  end

  test "missing pty=: returns invalid_args" do
    assert {:error, %{"type" => "invalid_args"}} =
             Attach.execute(%{"submitted_by" => "linyilun", "args" => %{}})
  end
end
