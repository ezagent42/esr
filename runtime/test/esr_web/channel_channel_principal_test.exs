defmodule EsrWeb.ChannelChannelPrincipalTest do
  @moduledoc """
  Capabilities spec §6.2/§6.3 (CAP-3 wiring) — the CC-side
  ChannelChannel captures ``principal_id`` + ``workspace_name`` on the
  ``session_register`` envelope, stashes them on the socket, and
  forwards ``principal_id`` into the arity-6 ``{:tool_invoke, ...}``
  tuple sent to the bound Entity.Server.

  Lane B enforcement (denying based on the principal's grants) lands
  in CAP-4 — these tests only verify the plumbing.
  """

  use EsrWeb.ChannelCase, async: false

  alias Esr.AdapterSocketRegistry

  setup do
    # Guard against a stale env var leaking in from other tests in the
    # same run — the bootstrap fallback is tested explicitly below.
    old = System.get_env("ESR_BOOTSTRAP_PRINCIPAL_ID")
    System.delete_env("ESR_BOOTSTRAP_PRINCIPAL_ID")
    on_exit(fn ->
      if old, do: System.put_env("ESR_BOOTSTRAP_PRINCIPAL_ID", old),
        else: System.delete_env("ESR_BOOTSTRAP_PRINCIPAL_ID")
    end)

    :ok
  end

  test "session_register persists principal_id + workspace_name to the registry" do
    sid = "princ-#{System.unique_integer([:positive])}"

    {:ok, _reply, socket} =
      EsrWeb.ChannelSocket
      |> socket("ch-conn", %{})
      |> subscribe_and_join(EsrWeb.ChannelChannel, "cli:channel/" <> sid)

    push(socket, "envelope", %{
      "kind" => "session_register",
      "workspace" => "esr-dev",
      "principal_id" => "ou_alice",
      "workspace_name" => "proj-a",
      "chats" => [%{"chat_id" => "oc_x", "app_id" => "cli_x", "kind" => "dm"}]
    })

    Process.sleep(50)

    {:ok, row} = AdapterSocketRegistry.lookup(sid)
    assert row.principal_id == "ou_alice"
    assert row.workspace_name == "proj-a"
  end

  test "tool_invoke after session_register sends arity-6 tuple with principal_id" do
    sid = "princ-tool-#{System.unique_integer([:positive])}"
    actor_id = "thread:" <> sid

    # Register self() as the "Entity.Server" so assert_receive catches the
    # tuple the ChannelChannel sends.
    {:ok, _} = Registry.register(Esr.Entity.Registry, actor_id, nil)

    {:ok, _reply, socket} =
      EsrWeb.ChannelSocket
      |> socket("ch-conn", %{})
      |> subscribe_and_join(EsrWeb.ChannelChannel, "cli:channel/" <> sid)

    push(socket, "envelope", %{
      "kind" => "session_register",
      "workspace" => "esr-dev",
      "principal_id" => "ou_alice",
      "workspace_name" => "proj-a",
      "chats" => []
    })

    # Let the register frame apply.
    Process.sleep(50)

    push(socket, "envelope", %{
      "kind" => "tool_invoke",
      "req_id" => "r1",
      "tool" => "reply",
      "args" => %{"chat_id" => "oc_x", "text" => "hi"}
    })

    # Arity 6: principal_id is the 6th element. CAP-3 only threads it
    # through — the current Entity.Server clause ignores the value.
    assert_receive {:tool_invoke, "r1", "reply", %{"text" => "hi"}, _reply_pid,
                    "ou_alice"},
                   500
  end

  test "tool_invoke without prior session_register defaults to ESR_BOOTSTRAP_PRINCIPAL_ID" do
    sid = "princ-boot-#{System.unique_integer([:positive])}"
    actor_id = "thread:" <> sid
    {:ok, _} = Registry.register(Esr.Entity.Registry, actor_id, nil)

    System.put_env("ESR_BOOTSTRAP_PRINCIPAL_ID", "ou_bootstrap_admin")

    {:ok, _reply, socket} =
      EsrWeb.ChannelSocket
      |> socket("ch-conn", %{})
      |> subscribe_and_join(EsrWeb.ChannelChannel, "cli:channel/" <> sid)

    push(socket, "envelope", %{
      "kind" => "tool_invoke",
      "req_id" => "r2",
      "tool" => "_echo",
      "args" => %{"nonce" => "n"}
    })

    assert_receive {:tool_invoke, "r2", "_echo", _args, _reply_pid,
                    "ou_bootstrap_admin"},
                   500
  end

  test "session_register without principal_id falls back to bootstrap env var" do
    sid = "princ-fb-#{System.unique_integer([:positive])}"
    System.put_env("ESR_BOOTSTRAP_PRINCIPAL_ID", "ou_bootstrap_admin")

    {:ok, _reply, socket} =
      EsrWeb.ChannelSocket
      |> socket("ch-conn", %{})
      |> subscribe_and_join(EsrWeb.ChannelChannel, "cli:channel/" <> sid)

    push(socket, "envelope", %{
      "kind" => "session_register",
      "workspace" => "esr-dev",
      "chats" => []
    })

    Process.sleep(50)

    {:ok, row} = AdapterSocketRegistry.lookup(sid)
    assert row.principal_id == "ou_bootstrap_admin"
    assert row.workspace_name == nil
  end
end
