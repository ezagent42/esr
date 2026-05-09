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

  test "with pty=<id>: emits a URL containing a signed token (not the actor_id)" do
    actor_id = "pty-uuid-attach"
    cmd = %{"submitted_by" => "linyilun", "args" => %{"pty" => actor_id}}
    assert {:ok, %{"text" => text, "url" => url, "pty" => ^actor_id}} = Attach.execute(cmd)

    # The actor_id remains in the body fields (display) and uri (esr://)
    # but MUST NOT appear in the http URL — that's the gap this PR closes.
    assert text =~ actor_id
    assert url =~ "/sessions/attach?token="
    refute url =~ actor_id

    # The token in the URL must verify back to the actor_id under the
    # same salt + the same 10-minute TTL the PtySocket enforces.
    [_, token] = Regex.run(~r/token=([^"&\s)]+)/, url)

    assert {:ok, decoded_actor_id} =
             Phoenix.Token.verify(EsrWeb.Endpoint, "pty_attach", token, max_age: 600)

    assert decoded_actor_id == actor_id
  end

  test "missing pty=: returns invalid_args" do
    assert {:error, %{"type" => "invalid_args"}} =
             Attach.execute(%{"submitted_by" => "linyilun", "args" => %{}})
  end
end
