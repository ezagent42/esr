defmodule Esr.Peers.CCProcessTest do
  @moduledoc """
  P3-2.1 — `Esr.Peers.CCProcess` is a per-Session `Peer.Stateful` that holds
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

  alias Esr.Peers.CCProcess

  @handler_module "cc_adapter_runner"

  test "on {:text, bytes}, buffers send_input until cc_mcp_ready flushes it" do
    me = self()
    pty = spawn_link(fn -> relay(me) end)
    cc_proxy = spawn_link(fn -> relay(me) end)

    {:ok, pid} =
      CCProcess.start_link(%{
        session_id: "sid1",
        handler_module: @handler_module,
        neighbors: [pty_process: pty, cc_proxy: cc_proxy],
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

    envelope = Esr.Peers.CCProcess.build_channel_notification(state, "hello")
    assert envelope["app_id"] == "feishu_DEV"
    assert envelope["chat_id"] == "oc_PRA"
    assert envelope["content"] == "hello"
  end

  # ------------------------------------------------------------------
  # PR-C C5: <channel> tag extensions — user_id, workspace, reachable
  # ------------------------------------------------------------------

  describe "build_channel_notification/2 — PR-C extensions" do
    test "emits user_id alongside user (both = sender_id today)" do
      state = %{
        session_id: "sC5_a",
        proxy_ctx: %{},
        last_meta: %{sender_id: "ou_alice", chat_id: "", app_id: ""},
        reachable_set: MapSet.new()
      }

      env = Esr.Peers.CCProcess.build_channel_notification(state, "hi")
      assert env["user"] == "ou_alice"
      assert env["user_id"] == "ou_alice"
    end

    test "omits 'reachable' when reachable_set is empty" do
      state = %{
        session_id: "sC5_b",
        proxy_ctx: %{},
        last_meta: %{},
        reachable_set: MapSet.new()
      }

      env = Esr.Peers.CCProcess.build_channel_notification(state, "x")
      refute Map.has_key?(env, "reachable")
    end

    test "emits 'reachable' as JSON-string attribute when reachable_set is populated (PR-D D2)" do
      state = %{
        session_id: "sC5_c",
        proxy_ctx: %{},
        last_meta: %{},
        reachable_set:
          MapSet.new([
            "esr://localhost/users/ou_admin",
            "esr://localhost/adapters/feishu/cli_app1"
          ])
      }

      env = Esr.Peers.CCProcess.build_channel_notification(state, "x")
      assert is_binary(env["reachable"])

      decoded = Jason.decode!(env["reachable"])
      assert is_list(decoded)
      assert length(decoded) == 2

      uris = Enum.map(decoded, & &1["uri"])
      assert "esr://localhost/users/ou_admin" in uris
      assert "esr://localhost/adapters/feishu/cli_app1" in uris

      for actor <- decoded do
        assert is_binary(actor["name"])
      end
    end

    test "reachable JSON entries are sorted by URI for prompt determinism" do
      state = %{
        session_id: "sC5_d",
        proxy_ctx: %{},
        last_meta: %{},
        reachable_set: MapSet.new(["esr://localhost/users/zzz", "esr://localhost/users/aaa"])
      }

      env = Esr.Peers.CCProcess.build_channel_notification(state, "x")
      decoded = Jason.decode!(env["reachable"])
      uris = Enum.map(decoded, & &1["uri"])
      assert uris == ["esr://localhost/users/aaa", "esr://localhost/users/zzz"]
    end
  end

  # ------------------------------------------------------------------
  # PR-C C4: BGP-style URI learning from upstream meta
  # ------------------------------------------------------------------

  describe "BGP-style learn_uris (PR-C C4)" do
    test "learns source URI from meta when not already in reachable_set" do
      me = self()
      pty = spawn_link(fn -> relay(me) end)
      cc_proxy = spawn_link(fn -> relay(me) end)

      {:ok, pid} =
        CCProcess.start_link(%{
          session_id: "sC4_a",
          handler_module: @handler_module,
          neighbors: [pty_process: pty, cc_proxy: cc_proxy],
          proxy_ctx: %{}
        })

      :ok =
        CCProcess.put_handler_override(pid, fn _mod, _payload, _timeout ->
          {:ok, %{}, []}
        end)

      meta = %{
        chat_id: "oc_a",
        app_id: "cli_a",
        sender_id: "ou_alice",
        message_id: "om_1",
        thread_id: "",
        source: "esr://localhost/adapters/feishu/cli_a",
        principal_id: "ou_alice"
      }

      send(pid, {:text, "hi", meta})
      Process.sleep(80)

      state = :sys.get_state(pid)
      assert MapSet.member?(state.reachable_set, "esr://localhost/adapters/feishu/cli_a")
      # principal_id lifted into a user URI:
      assert MapSet.member?(state.reachable_set, "esr://localhost/users/ou_alice")
    end

    test "topology hot-reload broadcast adds URI to reachable_set" do
      me = self()
      pty = spawn_link(fn -> relay(me) end)
      cc_proxy = spawn_link(fn -> relay(me) end)

      {:ok, pid} =
        CCProcess.start_link(%{
          session_id: "sC4_b",
          handler_module: @handler_module,
          neighbors: [pty_process: pty, cc_proxy: cc_proxy],
          proxy_ctx: %{workspace_name: "ws_x"}
        })

      send(pid, {:topology_neighbour_added, "ws_x", "esr://localhost/users/ou_admin"})
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert MapSet.member?(state.reachable_set, "esr://localhost/users/ou_admin")
    end

    test "topology_neighbour_added is idempotent" do
      me = self()
      pty = spawn_link(fn -> relay(me) end)
      cc_proxy = spawn_link(fn -> relay(me) end)

      {:ok, pid} =
        CCProcess.start_link(%{
          session_id: "sC4_c",
          handler_module: @handler_module,
          neighbors: [pty_process: pty, cc_proxy: cc_proxy],
          proxy_ctx: %{}
        })

      uri = "esr://localhost/users/ou_x"
      send(pid, {:topology_neighbour_added, "ws_x", uri})
      send(pid, {:topology_neighbour_added, "ws_x", uri})
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert MapSet.size(state.reachable_set) == 1
    end
  end

  defp relay(reply_to) do
    receive do
      msg ->
        send(reply_to, {:relay, msg})
        relay(reply_to)
    end
  end
end
