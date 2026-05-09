defmodule Esr.Plugins.ClaudeCode.Commands.TuiTest do
  @moduledoc """
  `/claude_code:tui name=<agent>` — claude_code plugin command.
  Spec rev-4 §4.4 + D5. Phase E task E.3.
  """

  use ExUnit.Case, async: false
  alias Esr.Plugins.ClaudeCode.Commands.Tui

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

  test "name=<agent>: resolves to PTY id and emits URL via /pty:attach" do
    chat = "oc_b1_tui_a"
    app = "esr_helper_tui_a"
    sid = "11111111-aaaa-4aaa-8aaa-111111111111"
    :ok = Esr.Session.ChatRouting.Registry.attach_session(chat, app, sid)

    tab = GenServer.call(Esr.Entity.Agent.InstanceRegistry, :table_name)

    inst = %Esr.Entity.Agent.Instance{
      id: "cc-uuid-tui",
      session_id: sid,
      type: "cc",
      name: "alice",
      config: %{},
      created_at: "2026-05-08T00:00:00Z",
      actor_ids: %{cc: "cc-uuid-tui", pty: "pty-uuid-tui-aaaa"}
    }

    :ets.insert(tab, {{sid, "alice"}, inst})

    cmd = %{
      "submitted_by" => "linyilun",
      "args" => %{"name" => "alice", "chat_id" => chat, "app_id" => app}
    }

    assert {:ok, %{"url" => url}} = Tui.execute(cmd)

    # Per the 2026-05-09 PtySocket auth PR, /pty:attach URLs no longer
    # contain the actor_id — they carry a Phoenix.Token signed under
    # salt "pty_attach". Tui delegates verbatim to Pty.Attach so the
    # contract is the same: actor_id must verify back from the token.
    assert url =~ "/sessions/attach?token="
    refute url =~ "pty-uuid-tui-aaaa"

    [_, token] = Regex.run(~r/token=([^"&\s)]+)/, url)
    raw_token = URI.decode_www_form(token)

    assert {:ok, "pty-uuid-tui-aaaa"} =
             Phoenix.Token.verify(EsrWeb.Endpoint, "pty_attach", raw_token, max_age: 600)
  end

  test "unknown agent name: returns not_found" do
    chat = "oc_b1_tui_b"
    app = "esr_helper_tui_b"
    sid = "22222222-bbbb-4bbb-8bbb-222222222222"
    :ok = Esr.Session.ChatRouting.Registry.attach_session(chat, app, sid)

    cmd = %{
      "submitted_by" => "linyilun",
      "args" => %{"name" => "ghost", "chat_id" => chat, "app_id" => app}
    }

    assert {:error, %{"type" => "not_found"}} = Tui.execute(cmd)
  end

  test "missing name arg: returns invalid_args" do
    cmd = %{"submitted_by" => "linyilun", "args" => %{"chat_id" => "c", "app_id" => "a"}}
    assert {:error, %{"type" => "invalid_args"}} = Tui.execute(cmd)
  end

  test "missing chat context: returns invalid_args" do
    cmd = %{"submitted_by" => "linyilun", "args" => %{"name" => "alice"}}
    assert {:error, %{"type" => "invalid_args"}} = Tui.execute(cmd)
  end
end
