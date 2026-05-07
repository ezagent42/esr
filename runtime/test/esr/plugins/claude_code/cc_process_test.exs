defmodule Esr.Entity.CCProcessTest do
  @moduledoc """
  P3-2.1 — `Esr.Entity.CCProcess` is a per-Session `Peer.Stateful` that holds
  CC business state and invokes the Python handler via `Esr.HandlerRouter.call/3`
  on upstream messages. Handler actions are translated into downstream messages:
  `:send_input` to the PTY peer neighbor, `:reply` upward to the CCProxy
  neighbor (which forwards to FeishuChatProxy in PR-3).

  Tests stub `HandlerRouter.call/3` via a process-dict override
  (`:cc_handler_override`) — the real PubSub round-trip is exercised by the
  integration lanes.

  Spec §4.1 CCProcess card, §5.1 data flow; expansion P3-2.
  """
  use ExUnit.Case, async: false

  alias Esr.Entity.CCProcess

  @handler_module "cc_adapter_runner"

  # The pre-PR-24 "buffer send_input + flush on cc_mcp_ready" assertion
  # that used to live here was rewritten in
  # test/esr/entity/cc_process_inbound_regression_test.exs to match
  # production: post-PR-24 dispatch_action routes not-ready send_input
  # to PtyProcess.write (boot-bridge fallback), no buffer-then-flush.
  # See companion RCA in feature/cc-inbound-regression-tests.

  test "on {:legacy_output, bytes}, drops silently (legacy diagnostic — production never sends this)" do
    # Post-T11b the conversation path runs through cli:channel MCP
    # notifications, not raw stdout capture. Stale stdout messages
    # carrying CC's TUI chrome (ANSI, box-drawing, partial-UTF8 bursts
    # from reads splitting a multibyte char mid-stream) must NOT invoke
    # the handler — Jason.encode!/1 crashed CCProcess on truncated UTF-8.
    me = self()
    pty = spawn_link(fn -> relay(me) end)
    cc_proxy = spawn_link(fn -> relay(me) end)

    {:ok, pid} =
      CCProcess.start_link(%{
        session_id: "sid2",
        handler_module: @handler_module,
        neighbors: [pty_process: pty, cc_proxy: cc_proxy],
        proxy_ctx: %{}
      })

    handler_called = :atomics.new(1, [])

    :ok =
      CCProcess.put_handler_override(pid, fn _mod, _payload, _timeout ->
        :atomics.add(handler_called, 1, 1)
        {:ok, %{}, []}
      end)

    # Fire a truncated-UTF8 burst similar to what a stdout-capture peer
    # would emit (partial box-drawing char) — regression pin for the
    # 2026-04-24 Jason.EncodeError.
    send(pid, {:legacy_output, <<59, 50, 50, 48, 109, 226, 148, 128, 226>>})

    Process.sleep(100)
    assert Process.alive?(pid)
    assert :atomics.get(handler_called, 1) == 0
    refute_receive {:relay, _}, 50
  end

  test "HandlerRouter timeout drops the message and logs" do
    me = self()
    pty = spawn_link(fn -> relay(me) end)
    cc_proxy = spawn_link(fn -> relay(me) end)

    {:ok, pid} =
      CCProcess.start_link(%{
        session_id: "sid3",
        handler_module: @handler_module,
        neighbors: [pty_process: pty, cc_proxy: cc_proxy],
        proxy_ctx: %{}
      })

    :ok =
      CCProcess.put_handler_override(pid, fn _mod, _payload, _timeout ->
        {:error, :handler_timeout}
      end)

    send(pid, {:text, "x"})
    refute_receive {:relay, _}, 200
  end

  test "handler state is carried across successive upstream messages" do
    me = self()
    pty = spawn_link(fn -> relay(me) end)
    cc_proxy = spawn_link(fn -> relay(me) end)

    {:ok, pid} =
      CCProcess.start_link(%{
        session_id: "sid4",
        handler_module: @handler_module,
        initial_state: %{"turn" => 0},
        neighbors: [pty_process: pty, cc_proxy: cc_proxy],
        proxy_ctx: %{}
      })

    test_pid = self()

    :ok =
      CCProcess.put_handler_override(pid, fn _mod, payload, _timeout ->
        send(test_pid, {:handler_saw_state, payload["state"]})
        new_turn = Map.get(payload["state"], "turn", 0) + 1
        {:ok, %{"turn" => new_turn}, []}
      end)

    send(pid, {:text, "a"})
    assert_receive {:handler_saw_state, %{"turn" => 0}}, 500

    send(pid, {:text, "b"})
    assert_receive {:handler_saw_state, %{"turn" => 1}}, 500
  end

  test "unknown action types are dropped without crashing the peer" do
    me = self()
    pty = spawn_link(fn -> relay(me) end)
    cc_proxy = spawn_link(fn -> relay(me) end)

    {:ok, pid} =
      CCProcess.start_link(%{
        session_id: "sid5",
        handler_module: @handler_module,
        neighbors: [pty_process: pty, cc_proxy: cc_proxy],
        proxy_ctx: %{}
      })

    :ok =
      CCProcess.put_handler_override(pid, fn _mod, _payload, _timeout ->
        {:ok, %{}, [%{"type" => "mystery", "text" => "?"}]}
      end)

    send(pid, {:text, "a"})
    refute_receive {:relay, _}, 100
    assert Process.alive?(pid)
  end

  test "build_channel_notification includes app_id from upstream meta" do
    state = %{
      session_id: "S_PRA2",
      proxy_ctx: %{"channel_adapter" => "feishu"},
      last_meta: %{
        chat_id: "oc_PRA",
        app_id: "feishu_DEV",
        thread_id: "",
        message_id: "om_X",
        sender_id: "ou_someone"
      }
    }

    envelope = Esr.Entity.CCProcess.build_channel_notification(state, "hello")
    assert envelope["app_id"] == "feishu_DEV"
    assert envelope["chat_id"] == "oc_PRA"
    assert envelope["content"] == "hello"
  end

  # ------------------------------------------------------------------
  # <channel> tag extensions — user_id forwarding from sender meta
  # ------------------------------------------------------------------

  describe "build_channel_notification/2" do
    test "emits user_id alongside user (both = sender_id today)" do
      state = %{
        session_id: "sC5_a",
        proxy_ctx: %{},
        last_meta: %{sender_id: "ou_alice", chat_id: "", app_id: ""}
      }

      env = Esr.Entity.CCProcess.build_channel_notification(state, "hi")
      assert env["user"] == "ou_alice"
      assert env["user_id"] == "ou_alice"
    end
  end

  # M-3: PR-C C4/C5/D2 reachable_set + topology hot-reload + BGP-style URI
  # learning all deleted. Routing coverage now lives in
  # runtime/test/esr/actor_query_test.exs and the integration scenarios in
  # tests/e2e/.

  defp relay(reply_to) do
    receive do
      msg ->
        send(reply_to, {:relay, msg})
        relay(reply_to)
    end
  end
end
