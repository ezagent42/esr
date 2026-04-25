defmodule Esr.Peers.CCProcessTest do
  @moduledoc """
  P3-2.1 — `Esr.Peers.CCProcess` is a per-Session `Peer.Stateful` that holds
  CC business state and invokes the Python handler via `Esr.HandlerRouter.call/3`
  on upstream messages. Handler actions are translated into downstream messages:
  `:send_input` to the TmuxProcess neighbor, `:reply` upward to the CCProxy
  neighbor (which forwards to FeishuChatProxy in PR-3).

  Tests stub `HandlerRouter.call/3` via a process-dict override
  (`:cc_handler_override`) — the real PubSub round-trip is exercised by the
  integration lanes.

  Spec §4.1 CCProcess card, §5.1 data flow; expansion P3-2.
  """
  use ExUnit.Case, async: false

  alias Esr.Peers.CCProcess

  @handler_module "cc_adapter_runner"

  test "on {:text, bytes}, buffers send_input until cc_mcp_ready flushes it" do
    me = self()
    tmux = spawn_link(fn -> relay(me) end)
    cc_proxy = spawn_link(fn -> relay(me) end)

    {:ok, pid} =
      CCProcess.start_link(%{
        session_id: "sid1",
        handler_module: @handler_module,
        neighbors: [tmux_process: tmux, cc_proxy: cc_proxy],
        proxy_ctx: %{}
      })

    :ok =
      CCProcess.put_handler_override(pid, fn mod, _payload, _timeout ->
        assert mod == @handler_module
        {:ok, %{"history" => ["hello"]}, [%{"type" => "send_input", "text" => "hello\n"}]}
      end)

    # PR-9 T12-comms-3c: send_input is buffered when cc_mcp hasn't
    # joined cli:channel/<sid> yet (the common case for the first
    # auto-created inbound). Subscribe to the topic BEFORE the ready
    # signal so we only see the flush-on-ready broadcast — verifies
    # the buffered envelope comes through with correct content.
    :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "cli:channel/sid1")

    send(pid, {:text, "hello"})

    # With cc_mcp_ready = false (default), the send_input action is
    # buffered — nothing should hit the cli:channel topic yet.
    refute_receive {:notification, _}, 200

    # Simulate ChannelChannel's cc_mcp join → flush buffer.
    send(pid, {:cc_mcp_ready, "sid1"})

    assert_receive {:notification,
                    %{
                      "kind" => "notification",
                      "content" => "hello\n"
                    }},
                   500
  end

  test "on {:tmux_output, bytes}, drops silently (T11b.8 diagnostic-only)" do
    # Post-T11b the conversation path runs through cli:channel MCP
    # notifications, not tmux stdout capture. tmux_output carries CC's
    # TUI chrome (ANSI, box-drawing, partial-UTF8 bursts when tmux
    # reads split a multibyte char mid-stream) and must NOT invoke the
    # handler — Jason.encode!/1 crashed CCProcess on truncated UTF-8.
    me = self()
    tmux = spawn_link(fn -> relay(me) end)
    cc_proxy = spawn_link(fn -> relay(me) end)

    {:ok, pid} =
      CCProcess.start_link(%{
        session_id: "sid2",
        handler_module: @handler_module,
        neighbors: [tmux_process: tmux, cc_proxy: cc_proxy],
        proxy_ctx: %{}
      })

    handler_called = :atomics.new(1, [])

    :ok =
      CCProcess.put_handler_override(pid, fn _mod, _payload, _timeout ->
        :atomics.add(handler_called, 1, 1)
        {:ok, %{}, []}
      end)

    # Fire tmux_output with a truncated-UTF8 burst similar to what tmux
    # actually emits (partial box-drawing char) — regression pin for
    # the 2026-04-24 Jason.EncodeError.
    send(pid, {:tmux_output, <<59, 50, 50, 48, 109, 226, 148, 128, 226>>})

    Process.sleep(100)
    assert Process.alive?(pid)
    assert :atomics.get(handler_called, 1) == 0
    refute_receive {:relay, _}, 50
  end

  test "HandlerRouter timeout drops the message and logs" do
    me = self()
    tmux = spawn_link(fn -> relay(me) end)
    cc_proxy = spawn_link(fn -> relay(me) end)

    {:ok, pid} =
      CCProcess.start_link(%{
        session_id: "sid3",
        handler_module: @handler_module,
        neighbors: [tmux_process: tmux, cc_proxy: cc_proxy],
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
    tmux = spawn_link(fn -> relay(me) end)
    cc_proxy = spawn_link(fn -> relay(me) end)

    {:ok, pid} =
      CCProcess.start_link(%{
        session_id: "sid4",
        handler_module: @handler_module,
        initial_state: %{"turn" => 0},
        neighbors: [tmux_process: tmux, cc_proxy: cc_proxy],
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
    tmux = spawn_link(fn -> relay(me) end)
    cc_proxy = spawn_link(fn -> relay(me) end)

    {:ok, pid} =
      CCProcess.start_link(%{
        session_id: "sid5",
        handler_module: @handler_module,
        neighbors: [tmux_process: tmux, cc_proxy: cc_proxy],
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

  defp relay(reply_to) do
    receive do
      msg ->
        send(reply_to, {:relay, msg})
        relay(reply_to)
    end
  end
end
