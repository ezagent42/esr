defmodule Esr.Peers.FeishuChatProxyTest do
  use ExUnit.Case, async: false

  alias Esr.Peers.FeishuChatProxy

  setup do
    # Drift from expansion doc: both `Esr.SessionRegistry` (via 4d) and
    # `Esr.Scope.Admin.Process` (via P2-9's Scope.Admin) are now started
    # at app boot, so a redundant `start_supervised!` would crash with
    # :already_started. We reuse the app-level processes; register_admin_peer
    # is idempotent per-key so cross-test pollution is bounded.
    assert is_pid(Process.whereis(Esr.SessionRegistry))
    assert is_pid(Process.whereis(Esr.Scope.Admin.Process))
    :ok
  end

  # PR-21κ Phase 6: the "slash-prefix messages route to slash_handler"
  # test deleted. Slashes never reach FCP anymore — the FAA intercepts
  # them upstream and dispatches via `Esr.Peers.SlashHandler.dispatch/3`.
  # FCP is now purely "forward inbound text to the CC session"; the
  # tests in the next describe block exercise that single
  # responsibility.

  describe "non-slash text forward to CC (PR-9 T5a / PR-21λ)" do
    test "forwards {:text, bytes} to cc_process neighbor; FCP no longer emits react (PR-21λ — FAA owns it)" do
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

      # PR-21λ: FCP no longer emits the inbound react —
      # FAA emits the universal "received" emoji on every inbound.
      refute_receive {:relay, :app, {:outbound, %{"kind" => "react"}}}, 100
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

  describe "CC reply → forward reply with reply_to_message_id passthrough (PR-21λ)" do
    test "{:reply, text, %{reply_to_message_id: mid}} threads mid into outbound for FAA un_react" do
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

      send(peer, {:reply, "done", %{reply_to_message_id: "om_inbound_42"}})

      # PR-21λ: FCP no longer un_reacts itself. It threads
      # `reply_to_message_id` through the outbound envelope so FAA's
      # `handle_downstream` can un_react the universal "received" emoji.
      assert_receive {:relay, :app,
                      {:outbound,
                       %{
                         "kind" => "reply",
                         "args" => %{
                           "chat_id" => "oc_un",
                           "text" => "done",
                           "reply_to_message_id" => "om_inbound_42"
                         }
                       }}},
                     500

      # And NOT a separate un_react envelope (FCP doesn't emit one anymore).
      refute_receive {:relay, :app, {:outbound, %{"kind" => "un_react"}}}, 100
    end

    test "{:reply, text} (no opts) forwards reply without reply_to_message_id" do
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

      send(peer, {:reply, "proactive message"})

      assert_receive {:relay, :app,
                      {:outbound, %{"kind" => "reply", "args" => args}}},
                     500

      assert args["text"] == "proactive message"
      assert args["chat_id"] == "oc_bwc"
      refute Map.has_key?(args, "reply_to_message_id")
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

    test "send_file tool reads file + emits α wire shape (file_name + content_b64 + sha256)" do
      # T12-comms-3g: FCP translates CC's MCP tool (chat_id + file_path)
      # into the feishu adapter's α wire shape (file_name + content_b64
      # + sha256) by reading the local file. Write a temp file so the
      # read succeeds deterministically.
      path = Path.join(System.tmp_dir!(), "fcp_sendfile_#{System.unique_integer([:positive])}.txt")
      File.write!(path, "hello fcp send_file")
      on_exit(fn -> File.rm(path) end)

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
                  %{"chat_id" => "oc_sf", "file_path" => path},
                  self(), "ou_admin"})

      expected_b64 = Base.encode64("hello fcp send_file")
      expected_sha = :crypto.hash(:sha256, "hello fcp send_file") |> Base.encode16(case: :lower)
      expected_name = Path.basename(path)

      assert_receive {:relay, :app,
                      {:outbound,
                       %{
                         "kind" => "send_file",
                         "args" => %{
                           "chat_id" => "oc_sf",
                           "file_name" => ^expected_name,
                           "content_b64" => ^expected_b64,
                           "sha256" => ^expected_sha
                         }
                       }}},
                     500

      assert_receive {:push_envelope, %{"req_id" => "req-2", "ok" => true}}, 500
    end

    test "send_file rejects relative paths + paths containing `..`" do
      me = self()
      app_proxy = spawn_link(fn -> relay(me, :app) end)

      {:ok, peer} =
        GenServer.start_link(FeishuChatProxy, %{
          session_id: "s_sf_rel",
          chat_id: "oc_sfr",
          thread_id: "om_sfr",
          neighbors: [feishu_app_proxy: app_proxy],
          proxy_ctx: %{}
        })

      # Relative path → rejected
      send(peer, {:tool_invoke, "req-rel", "send_file",
                  %{"chat_id" => "oc_sfr", "file_path" => "etc/passwd"},
                  self(), "ou_admin"})

      assert_receive {:push_envelope, %{"req_id" => "req-rel", "ok" => false}}, 500
      refute_receive {:relay, :app, _}, 100

      # Absolute but contains `..` → rejected (defence-in-depth even
      # though Path.expand would resolve it).
      send(peer, {:tool_invoke, "req-trav", "send_file",
                  %{"chat_id" => "oc_sfr", "file_path" => "/tmp/foo/../../etc/passwd"},
                  self(), "ou_admin"})

      assert_receive {:push_envelope, %{"req_id" => "req-trav", "ok" => false}}, 500
      refute_receive {:relay, :app, _}, 100
    end

    test "send_file with missing file returns tool_result ok:false + read_failed" do
      me = self()
      app_proxy = spawn_link(fn -> relay(me, :app) end)

      {:ok, peer} =
        GenServer.start_link(FeishuChatProxy, %{
          session_id: "s_sf_missing",
          chat_id: "oc_sfm",
          thread_id: "om_sfm",
          neighbors: [feishu_app_proxy: app_proxy],
          proxy_ctx: %{}
        })

      send(peer, {:tool_invoke, "req-3", "send_file",
                  %{"chat_id" => "oc_sfm", "file_path" => "/tmp/this-file-does-not-exist-esr-test"},
                  self(), "ou_admin"})

      assert_receive {:push_envelope, %{
                        "req_id" => "req-3",
                        "ok" => false,
                        "error" => %{"type" => "read_failed"}
                      }},
                     500

      refute_receive {:relay, :app, _}, 200
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
