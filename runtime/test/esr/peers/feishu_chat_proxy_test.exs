defmodule Esr.Peers.FeishuChatProxyTest do
  use ExUnit.Case, async: false

  alias Esr.Peers.FeishuChatProxy

  setup do
    # Drift from expansion doc: both `Esr.SessionRegistry` (via 4d) and
    # `Esr.AdminSessionProcess` (via P2-9's AdminSession) are now started
    # at app boot, so a redundant `start_supervised!` would crash with
    # :already_started. We reuse the app-level processes; register_admin_peer
    # is idempotent per-key so cross-test pollution is bounded.
    assert is_pid(Process.whereis(Esr.SessionRegistry))
    assert is_pid(Process.whereis(Esr.AdminSessionProcess))
    :ok
  end

  test "slash-prefix messages route to slash_handler via AdminSessionProcess" do
    test_pid = self()
    :ok = Esr.AdminSessionProcess.register_admin_peer(:slash_handler, test_pid)

    {:ok, peer} =
      GenServer.start_link(FeishuChatProxy, %{
        session_id: "s1",
        chat_id: "oc_x",
        thread_id: "om_1",
        neighbors: [],
        proxy_ctx: %{}
      })

    send(peer, {:feishu_inbound, %{
      "payload" => %{
        "event_type" => "msg_received",
        "args" => %{"chat_id" => "oc_x", "content" => "/new-session --agent cc --dir /tmp/w"}
      }
    }})

    assert_receive {:slash_cmd, _env, reply_to}, 500
    assert reply_to == peer
  end

  describe "non-slash text forward to CC (PR-9 T5a)" do
    test "forwards {:text, bytes} to cc_process neighbor and emits react to feishu_app_proxy" do
      me = self()
      cc_process = spawn_link(fn -> relay(me, :cc) end)
      app_proxy = spawn_link(fn -> relay(me, :app) end)

      {:ok, peer} =
        GenServer.start_link(FeishuChatProxy, %{
          session_id: "s_fwd",
          chat_id: "oc_fwd",
          thread_id: "om_fwd",
          neighbors: [cc_process: cc_process, feishu_app_proxy: app_proxy],
          proxy_ctx: %{}
        })

      envelope = %{
        "payload" => %{
          "event_type" => "msg_received",
          "args" => %{
            "chat_id" => "oc_fwd",
            "content" => "hello, not a slash",
            "message_id" => "om_inbound_abc"
          }
        }
      }

      send(peer, {:feishu_inbound, envelope})

      # T11b.6a: 3-tuple carries message_id/sender_id/thread_id
      # downstream so T11b.6's notification meta has real attribution.
      assert_receive {:relay, :cc,
                      {:text, "hello, not a slash",
                       %{message_id: "om_inbound_abc", sender_id: _, thread_id: _}}},
                     500

      assert_receive {:relay, :app,
                      {:outbound,
                       %{
                         "kind" => "react",
                         "args" => %{
                           "msg_id" => "om_inbound_abc",
                           "emoji_type" => "EYES"
                         }
                       }}},
                     500

      # Pending react tracked in state so T5c's un_react path has the emoji.
      assert %{pending_reacts: %{"om_inbound_abc" => "EYES"}} = :sys.get_state(peer)
    end

    test "drops + warns when no cc_process neighbor is present" do
      import ExUnit.CaptureLog

      {:ok, peer} =
        GenServer.start_link(FeishuChatProxy, %{
          session_id: "s_no_cc",
          chat_id: "oc_no_cc",
          thread_id: "om_no_cc",
          neighbors: [],
          proxy_ctx: %{}
        })

      # Lower primary log level so capture_log sees the warning.
      original_level = Logger.level()
      Logger.configure(level: :warning)
      on_exit(fn -> Logger.configure(level: original_level) end)

      log =
        capture_log(fn ->
          send(peer, {:feishu_inbound, %{
            "payload" => %{
              "event_type" => "msg_received",
              "args" => %{"content" => "hello", "message_id" => "om_x"}
            }
          }})
          Process.sleep(50)
        end)

      assert log =~ "feishu_chat_proxy: non-slash text but no cc_process neighbor"
      assert Process.alive?(peer)
    end

    test "skips react emit when inbound envelope has no message_id" do
      me = self()
      cc_process = spawn_link(fn -> relay(me, :cc) end)
      app_proxy = spawn_link(fn -> relay(me, :app) end)

      {:ok, peer} =
        GenServer.start_link(FeishuChatProxy, %{
          session_id: "s_no_mid",
          chat_id: "oc_no_mid",
          thread_id: "om_no_mid",
          neighbors: [cc_process: cc_process, feishu_app_proxy: app_proxy],
          proxy_ctx: %{}
        })

      # No message_id in the envelope payload — nothing to react to.
      send(peer, {:feishu_inbound, %{
        "payload" => %{"event_type" => "msg_received", "args" => %{"content" => "hi"}}
      }})

      assert_receive {:relay, :cc, {:text, "hi", meta}}, 500
      assert is_map(meta)
      refute_receive {:relay, :app, _}, 100
    end
  end

  describe "CC reply → un_react then forward reply (PR-9 T5c)" do
    test "{:reply, text, %{reply_to_message_id: mid}} un-reacts then forwards reply" do
      me = self()
      app_proxy = spawn_link(fn -> relay(me, :app) end)

      {:ok, peer} =
        GenServer.start_link(FeishuChatProxy, %{
          session_id: "s_un",
          chat_id: "oc_un",
          thread_id: "om_un",
          neighbors: [feishu_app_proxy: app_proxy],
          proxy_ctx: %{}
        })

      # Seed pending_reacts as if a prior inbound had triggered a react.
      :sys.replace_state(peer, fn s ->
        Map.put(s, :pending_reacts, %{"om_inbound_42" => "EYES"})
      end)

      send(peer, {:reply, "done",
                  %{reply_to_message_id: "om_inbound_42"}})

      # Un_react fires BEFORE the reply text.
      assert_receive {:relay, :app,
                      {:outbound,
                       %{
                         "kind" => "un_react",
                         "args" => %{
                           "msg_id" => "om_inbound_42",
                           "emoji_type" => "EYES"
                         }
                       }}},
                     500

      assert_receive {:relay, :app,
                      {:outbound,
                       %{
                         "kind" => "reply",
                         "args" => %{"chat_id" => "oc_un", "text" => "done"}
                       }}},
                     500

      # Pending react cleared so a retry cannot double-un-react.
      assert %{pending_reacts: pr} = :sys.get_state(peer)
      refute Map.has_key?(pr, "om_inbound_42")
    end

    test "{:reply, text} (no opts) forwards reply without un_react (backward compat)" do
      me = self()
      app_proxy = spawn_link(fn -> relay(me, :app) end)

      {:ok, peer} =
        GenServer.start_link(FeishuChatProxy, %{
          session_id: "s_bwc",
          chat_id: "oc_bwc",
          thread_id: "om_bwc",
          neighbors: [feishu_app_proxy: app_proxy],
          proxy_ctx: %{}
        })

      # Pending react exists for a different message — must not be touched.
      :sys.replace_state(peer, fn s ->
        Map.put(s, :pending_reacts, %{"om_other" => "EYES"})
      end)

      send(peer, {:reply, "proactive message"})

      assert_receive {:relay, :app,
                      {:outbound,
                       %{
                         "kind" => "reply",
                         "args" => %{"chat_id" => "oc_bwc", "text" => "proactive message"}
                       }}},
                     500

      refute_receive {:relay, :app, {:outbound, %{"kind" => "un_react"}}}, 100

      # State unchanged.
      assert %{pending_reacts: %{"om_other" => "EYES"}} = :sys.get_state(peer)
    end

    test "reply with reply_to_message_id for an un-tracked message skips un_react" do
      me = self()
      app_proxy = spawn_link(fn -> relay(me, :app) end)

      {:ok, peer} =
        GenServer.start_link(FeishuChatProxy, %{
          session_id: "s_untrack",
          chat_id: "oc_untrack",
          thread_id: "om_untrack",
          neighbors: [feishu_app_proxy: app_proxy],
          proxy_ctx: %{}
        })

      # No pending reacts — CC references an inbound we never reacted to.
      send(peer, {:reply, "x", %{reply_to_message_id: "om_unknown"}})

      assert_receive {:relay, :app, {:outbound, %{"kind" => "reply"}}}, 500
      refute_receive {:relay, :app, {:outbound, %{"kind" => "un_react"}}}, 100
    end
  end

  describe "tool_invoke from ChannelChannel (PR-9 T11b.4)" do
    test "registers as thread:<sid> in Esr.PeerRegistry" do
      sid = "ti_#{System.unique_integer([:positive])}"

      {:ok, peer} =
        GenServer.start_link(FeishuChatProxy, %{
          session_id: sid,
          chat_id: "oc_x",
          thread_id: "om_x",
          neighbors: [],
          proxy_ctx: %{}
        })

      assert [{^peer, _}] = Registry.lookup(Esr.PeerRegistry, "thread:" <> sid)
    end

    test "reply tool emits outbound + tool_result back on channel_pid" do
      me = self()
      app_proxy = spawn_link(fn -> relay(me, :app) end)

      {:ok, peer} =
        GenServer.start_link(FeishuChatProxy, %{
          session_id: "s_tool_reply",
          chat_id: "oc_t",
          thread_id: "om_t",
          neighbors: [feishu_app_proxy: app_proxy],
          proxy_ctx: %{}
        })

      send(peer, {:tool_invoke, "req-1", "reply",
                  %{"chat_id" => "oc_t", "text" => "hi from CC"},
                  self(), "ou_admin"})

      # Outbound reply lands on app_proxy.
      assert_receive {:relay, :app,
                      {:outbound,
                       %{
                         "kind" => "reply",
                         "args" => %{"chat_id" => "oc_t", "text" => "hi from CC"}
                       }}},
                     500

      # Tool result routed back to channel_pid (our test process).
      assert_receive {:push_envelope,
                      %{
                        "kind" => "tool_result",
                        "req_id" => "req-1",
                        "ok" => true
                      }},
                     500
    end

    test "send_file tool emits send_file outbound + tool_result" do
      me = self()
      app_proxy = spawn_link(fn -> relay(me, :app) end)

      {:ok, peer} =
        GenServer.start_link(FeishuChatProxy, %{
          session_id: "s_sf",
          chat_id: "oc_sf",
          thread_id: "om_sf",
          neighbors: [feishu_app_proxy: app_proxy],
          proxy_ctx: %{}
        })

      send(peer, {:tool_invoke, "req-2", "send_file",
                  %{"chat_id" => "oc_sf", "file_path" => "/tmp/x.txt"},
                  self(), "ou_admin"})

      assert_receive {:relay, :app,
                      {:outbound,
                       %{
                         "kind" => "send_file",
                         "args" => %{"chat_id" => "oc_sf", "file_path" => "/tmp/x.txt"}
                       }}},
                     500

      assert_receive {:push_envelope, %{"req_id" => "req-2", "ok" => true}}, 500
    end

    test "unknown tool returns tool_result with ok:false + error" do
      {:ok, peer} =
        GenServer.start_link(FeishuChatProxy, %{
          session_id: "s_bad",
          chat_id: "oc_b",
          thread_id: "om_b",
          neighbors: [],
          proxy_ctx: %{}
        })

      send(peer, {:tool_invoke, "req-err", "pin_message", %{}, self(), "ou_admin"})

      assert_receive {:push_envelope,
                      %{
                        "kind" => "tool_result",
                        "req_id" => "req-err",
                        "ok" => false,
                        "error" => %{"type" => "unknown_tool"}
                      }},
                     500
    end
  end

  describe "channel_adapter lifted from ctx (D1)" do
    test "init/1 stores ctx.channel_adapter under string key in state" do
      args = %{
        session_id: "s1",
        chat_id: "oc_x",
        thread_id: "tg_x",
        neighbors: [],
        proxy_ctx: %{channel_adapter: "feishu_app"}
      }

      {:ok, state} = Esr.Peers.FeishuChatProxy.init(args)
      assert Map.get(state, "channel_adapter") == "feishu_app"
    end

    test "init/1 falls back to feishu when ctx is missing the key" do
      args = %{
        session_id: "s1",
        chat_id: "oc_x",
        thread_id: "tg_x",
        neighbors: [],
        proxy_ctx: %{}
      }

      {:ok, state} = Esr.Peers.FeishuChatProxy.init(args)
      assert Map.get(state, "channel_adapter") == "feishu"
    end
  end

  # Trivial relay: forward every received message to the test pid, tagged
  # with a label so tests can distinguish cc_process vs feishu_app_proxy.
  defp relay(reply_to, label) do
    receive do
      msg ->
        send(reply_to, {:relay, label, msg})
        relay(reply_to, label)
    end
  end
end
