defmodule Esr.Entity.FeishuChatProxyTest do
  use ExUnit.Case, async: false

  alias Esr.Entity.FeishuChatProxy

  setup do
    # Drift from expansion doc: both `Esr.SessionRegistry` (via 4d) and
    # `Esr.Session.Admin.Process` (via P2-9's Scope.Admin) are now started
    # at app boot, so a redundant `start_supervised!` would crash with
    # :already_started. We reuse the app-level processes; register_admin_peer
    # is idempotent per-key so cross-test pollution is bounded.
    assert is_pid(Process.whereis(Esr.Session.ChatRouting.Registry))
    assert is_pid(Process.whereis(Esr.Session.Admin.Process))
    :ok
  end

  # PR-21κ Phase 6: the "slash-prefix messages route to slash_handler"
  # test deleted. Slashes never reach FCP anymore — the FAA intercepts
  # them upstream and dispatches via `Esr.Entity.SlashHandler.dispatch/3`.
  # FCP is now purely "forward inbound text to the CC session"; the
  # tests in the next describe block exercise that single
  # responsibility.

  describe "non-slash text forward to CC (PR-9 T5a / PR-21λ)" do
    test "forwards {:text, bytes} to cc_process neighbor; FCP no longer emits react (PR-21λ — FAA owns it)" do
      me = self()
      cc_process = spawn_link(fn -> relay(me, :cc) end)
      app_proxy = spawn_link(fn -> relay(me, :app) end)

      _ = register_role(cc_process, "s_fwd", :cc_process)
      _ = register_role(app_proxy, "s_fwd", :feishu_app_proxy)

      {:ok, peer} =
        GenServer.start_link(FeishuChatProxy, %{
          session_id: "s_fwd",
          chat_id: "oc_fwd",
          thread_id: "om_fwd",
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

      # M-2.1: warning text changed (now references ActorQuery, not "neighbor").
      assert log =~ "feishu_chat_proxy: non-slash text but no cc_process found via ActorQuery"
      assert Process.alive?(peer)
    end

    test "skips react emit when inbound envelope has no message_id" do
      me = self()
      cc_process = spawn_link(fn -> relay(me, :cc) end)
      app_proxy = spawn_link(fn -> relay(me, :app) end)

      _ = register_role(cc_process, "s_no_mid", :cc_process)
      _ = register_role(app_proxy, "s_no_mid", :feishu_app_proxy)

      {:ok, peer} =
        GenServer.start_link(FeishuChatProxy, %{
          session_id: "s_no_mid",
          chat_id: "oc_no_mid",
          thread_id: "om_no_mid",
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

      _ = register_role(app_proxy, "s_un", :feishu_app_proxy)

      {:ok, peer} =
        GenServer.start_link(FeishuChatProxy, %{
          session_id: "s_un",
          chat_id: "oc_un",
          thread_id: "om_un",
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

      _ = register_role(app_proxy, "s_bwc", :feishu_app_proxy)

      {:ok, peer} =
        GenServer.start_link(FeishuChatProxy, %{
          session_id: "s_bwc",
          chat_id: "oc_bwc",
          thread_id: "om_bwc",
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
    # Tasks 3.1+3.2: send_file now routes through Esr.Resource.Media.store
    # before the α-wire dispatch. Tests that exercise the send_file path
    # must set up:
    #   1. ESRD_HOME (writable temp dir) so Media.store can persist bytes.
    #   2. PluginRegistry registration for "feishu" with matching outbound
    #      capability so check_outbound_capability/2 passes.
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "fcp_tool_invoke_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      saved_home = System.get_env("ESRD_HOME")
      saved_inst = System.get_env("ESR_INSTANCE")
      System.put_env("ESRD_HOME", tmp)
      System.put_env("ESR_INSTANCE", "test")

      # Register feishu plugin with full inbound+outbound capability so
      # send_file tests can exercise the happy-path without fighting the
      # capability check. Individual tests may override this via a second
      # register/2 call before sending the tool_invoke.
      Esr.Resource.Media.PluginRegistry.register("feishu", %{
        inbound: [:image, :file],
        outbound: [:image, :file]
      })

      on_exit(fn ->
        File.rm_rf!(tmp)
        Esr.Resource.Media.PluginRegistry.unregister("feishu")

        if saved_home,
          do: System.put_env("ESRD_HOME", saved_home),
          else: System.delete_env("ESRD_HOME")

        if saved_inst,
          do: System.put_env("ESR_INSTANCE", saved_inst),
          else: System.delete_env("ESR_INSTANCE")
      end)

      {:ok, tmp: tmp}
    end

    test "registers as thread:<sid> in Esr.Entity.Registry", %{tmp: _tmp} do
      sid = "ti_#{System.unique_integer([:positive])}"

      {:ok, peer} =
        GenServer.start_link(FeishuChatProxy, %{
          session_id: sid,
          chat_id: "oc_x",
          thread_id: "om_x",
          neighbors: [],
          proxy_ctx: %{}
        })

      assert [{^peer, _}] = Registry.lookup(Esr.Entity.Registry, "thread:" <> sid)
    end

    test "reply tool emits outbound + tool_result back on channel_pid", %{tmp: _tmp} do
      me = self()
      app_proxy = spawn_link(fn -> relay(me, :app) end)

      _ = register_role(app_proxy, "s_tool_reply", :feishu_app_proxy)

      {:ok, peer} =
        GenServer.start_link(FeishuChatProxy, %{
          session_id: "s_tool_reply",
          chat_id: "oc_t",
          thread_id: "om_t",
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

    test "send_file tool stores content-addressed bytes + emits α wire shape", %{tmp: tmp} do
      # Tasks 3.1+3.2 (spec D4): the new flow is:
      #   1. infer media_type from extension (.txt → :file)
      #   2. check_outbound_capability("feishu", :file) → :ok
      #   3. Esr.Resource.Media.store(:file, path, ref_meta) — content-addressed
      #   4. existing read_file_for_send + emit_to_feishu_app_proxy (α-wire UNCHANGED)
      path = Path.join(System.tmp_dir!(), "fcp_sendfile_#{System.unique_integer([:positive])}.txt")
      File.write!(path, "hello fcp send_file")
      on_exit(fn -> File.rm(path) end)

      me = self()
      app_proxy = spawn_link(fn -> relay(me, :app) end)

      _ = register_role(app_proxy, "s_sf", :feishu_app_proxy)

      {:ok, peer} =
        GenServer.start_link(FeishuChatProxy, %{
          session_id: "s_sf",
          chat_id: "oc_sf",
          thread_id: "om_sf",
          proxy_ctx: %{}
        })

      send(peer, {:tool_invoke, "req-2", "send_file",
                  %{"chat_id" => "oc_sf", "file_path" => path},
                  self(), "ou_admin"})

      expected_b64 = Base.encode64("hello fcp send_file")
      expected_sha = :crypto.hash(:sha256, "hello fcp send_file") |> Base.encode16(case: :lower)
      expected_name = Path.basename(path)

      # α-wire shape unchanged: file_name + content_b64 + sha256.
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

      # Content-addressed file written to ESRD_HOME.
      expected_path =
        Path.join([tmp, "test", "resources", "file", "#{expected_sha}.txt"])

      assert File.exists?(expected_path)

      # refs.jsonl has one entry recording cc as source actor.
      refs_path = Path.join([tmp, "test", "resources", "file", "#{expected_sha}.refs.jsonl"])
      assert File.exists?(refs_path)
      [ref_line | _] = File.read!(refs_path) |> String.split("\n", trim: true)
      decoded = Jason.decode!(ref_line)
      assert decoded["source_actor"] == "cc"
      assert decoded["chat_id"] == "oc_sf"
    end

    test "send_file image stores under resources/image/ with correct extension", %{tmp: tmp} do
      path = Path.join(System.tmp_dir!(), "fcp_img_#{System.unique_integer([:positive])}.png")
      File.write!(path, "fake png bytes")
      on_exit(fn -> File.rm(path) end)

      me = self()
      app_proxy = spawn_link(fn -> relay(me, :app) end)
      _ = register_role(app_proxy, "s_sf_img", :feishu_app_proxy)

      {:ok, peer} =
        GenServer.start_link(FeishuChatProxy, %{
          session_id: "s_sf_img",
          chat_id: "oc_img_out",
          thread_id: "om_img",
          proxy_ctx: %{}
        })

      send(peer, {:tool_invoke, "req-img", "send_file",
                  %{"chat_id" => "oc_img_out", "file_path" => path},
                  self(), "ou_admin"})

      expected_sha =
        :crypto.hash(:sha256, "fake png bytes") |> Base.encode16(case: :lower)

      assert_receive {:push_envelope, %{"req_id" => "req-img", "ok" => true}}, 500

      # Stored under resources/image/ (inferred from .png extension).
      assert File.exists?(
               Path.join([tmp, "test", "resources", "image", "#{expected_sha}.png"])
             )
    end

    test "send_file rejects when feishu doesn't declare outbound for the media_type", %{tmp: _tmp} do
      # Override: feishu outbound = [] (no image, no file)
      Esr.Resource.Media.PluginRegistry.register("feishu", %{inbound: [], outbound: []})

      path = Path.join(System.tmp_dir!(), "fcp_cap_#{System.unique_integer([:positive])}.png")
      File.write!(path, "data")
      on_exit(fn -> File.rm(path) end)

      me = self()
      app_proxy = spawn_link(fn -> relay(me, :app) end)
      _ = register_role(app_proxy, "s_sf_cap", :feishu_app_proxy)

      {:ok, peer} =
        GenServer.start_link(FeishuChatProxy, %{
          session_id: "s_sf_cap",
          chat_id: "oc_cap",
          thread_id: "om_cap",
          proxy_ctx: %{}
        })

      send(peer, {:tool_invoke, "req-cap", "send_file",
                  %{"chat_id" => "oc_cap", "file_path" => path},
                  self(), "ou_admin"})

      assert_receive {:push_envelope, %{
                        "req_id" => "req-cap",
                        "ok" => false,
                        "error" => %{"type" => "unsupported_outbound"}
                      }},
                     500

      # α-wire must NOT be emitted when capability check fails.
      refute_receive {:relay, :app, _}, 100
    end

    test "send_file rejects extensionless file_path with no_extension error", %{tmp: _tmp} do
      me = self()
      app_proxy = spawn_link(fn -> relay(me, :app) end)

      {:ok, peer} =
        GenServer.start_link(FeishuChatProxy, %{
          session_id: "s_sf_noext",
          chat_id: "oc_noext",
          thread_id: "om_noext",
          proxy_ctx: %{}
        })

      # File with no extension — rejected before any disk I/O.
      send(peer, {:tool_invoke, "req-noext", "send_file",
                  %{"chat_id" => "oc_noext", "file_path" => "/tmp/no_extension_file"},
                  self(), "ou_admin"})

      assert_receive {:push_envelope, %{
                        "req_id" => "req-noext",
                        "ok" => false,
                        "error" => %{"type" => "no_extension"}
                      }},
                     500

      refute_receive {:relay, :app, _}, 100
    end

    test "send_file rejects relative paths + paths containing `..`", %{tmp: _tmp} do
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

      # Relative path (no extension) → no_extension (infer_media_type fires first).
      send(peer, {:tool_invoke, "req-rel", "send_file",
                  %{"chat_id" => "oc_sfr", "file_path" => "etc/passwd"},
                  self(), "ou_admin"})

      assert_receive {:push_envelope, %{"req_id" => "req-rel", "ok" => false}}, 500
      refute_receive {:relay, :app, _}, 100

      # Absolute but contains `..` and no extension → no_extension.
      send(peer, {:tool_invoke, "req-trav", "send_file",
                  %{"chat_id" => "oc_sfr", "file_path" => "/tmp/foo/../../etc/passwd"},
                  self(), "ou_admin"})

      assert_receive {:push_envelope, %{"req_id" => "req-trav", "ok" => false}}, 500
      refute_receive {:relay, :app, _}, 100
    end

    test "send_file with missing file returns tool_result ok:false + store_or_read_failed", %{tmp: _tmp} do
      # Missing-file path: the new flow hits Media.store before
      # read_file_for_send. Media.store calls compute_sha256 which reads
      # the file — so a missing file surfaces as store_or_read_failed
      # (was: read_failed). Use a .txt extension so infer_media_type
      # succeeds and the capability check passes before the read attempt.
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
                  %{
                    "chat_id" => "oc_sfm",
                    "file_path" => "/tmp/this-file-does-not-exist-esr-test.txt"
                  },
                  self(), "ou_admin"})

      assert_receive {:push_envelope, %{
                        "req_id" => "req-3",
                        "ok" => false,
                        "error" => %{"type" => "store_or_read_failed"}
                      }},
                     500

      refute_receive {:relay, :app, _}, 200
    end

    test "unknown tool returns tool_result with ok:false + error", %{tmp: _tmp} do
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

  describe "non-text inbound (Task 2.4)" do
    alias Esr.Resource.Media.PluginRegistry

    setup do
      # Clean up PluginRegistry entries for "claude_code" after each test.
      on_exit(fn -> PluginRegistry.unregister("claude_code") end)

      # Reset CapGuard media_unsupported_last_emit state between tests.
      if pid = Process.whereis(Esr.Entity.CapGuard) do
        :sys.replace_state(pid, fn state ->
          Map.put(state, :media_unsupported_last_emit, %{})
        end)
      end

      :ok
    end

    test "dispatches image inbound to cc_process as {:text, uri, meta} when cc supports image" do
      me = self()
      sid = "s_img_#{System.unique_integer([:positive])}"

      # cc_process relay: receives {:text, content, meta} and forwards to test.
      cc_process = spawn_link(fn -> relay(me, :cc) end)
      # app_proxy relay: receives {:outbound, directive} and publishes directive_ack.
      app_proxy = spawn_link(fn -> relay_with_directive_ack(me) end)

      _ = register_role(cc_process, sid, :cc_process)
      _ = register_role(app_proxy, sid, :feishu_app_proxy)

      {:ok, _peer} =
        GenServer.start_link(Esr.Entity.FeishuChatProxy, %{
          session_id: sid,
          chat_id: "oc_img",
          thread_id: "",
          proxy_ctx: %{}
        })

      PluginRegistry.register("claude_code", %{inbound: [:image, :file, :audio], outbound: []})

      fake_uri =
        "esr://test@localhost:4001/resources/image/" <>
          String.duplicate("a", 64) <> ".jpg"

      # Tell the relay what URI to use in the directive_ack.
      send(app_proxy, {:set_ack_uri, fake_uri})
      # Give relay time to store ack_uri before the inbound arrives.
      Process.sleep(10)

      envelope = %{
        "source" => "esr://default@localhost/adapters/feishu/img_inst",
        "principal_id" => "ou_img_user",
        "payload" => %{
          "event_type" => "msg_received",
          "args" => %{
            "chat_id" => "oc_img",
            "msg_type" => "image",
            "msg_id" => "om_img_1",
            "file_key" => "img_filekey_abc",
            "file_name" => "photo.jpg",
            "sender_id" => "ou_img_user"
          }
        }
      }

      [{fcp_pid, _}] = Registry.lookup(Esr.Entity.Registry, "thread:" <> sid)
      send(fcp_pid, {:feishu_inbound, envelope})

      # cc_process receives {:text, uri, meta} — meta carries msg_type: "image"
      assert_receive {:relay, :cc, {:text, ^fake_uri, meta}}, 5_000
      assert meta.msg_type == "image"
      assert meta.sender_id == "ou_img_user"
    end

    test "emits throttled DM when cc doesn't declare inbound for the kind" do
      me = self()
      sid = "s_unsup_#{System.unique_integer([:positive])}"
      instance_id = "faa_unsup_#{System.unique_integer([:positive])}"

      # Start a FAA so CapGuard can dispatch the DM.
      {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
      on_exit(fn -> if Process.alive?(sup), do: Process.exit(sup, :shutdown) end)

      {:ok, _faa_pid} =
        DynamicSupervisor.start_child(
          sup,
          {Esr.Entity.FeishuAppAdapter,
           %{instance_id: instance_id, neighbors: [], proxy_ctx: %{}}}
        )

      # Subscribe to the adapter channel so we can observe the DM directive.
      :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "adapter:feishu/#{instance_id}")

      cc_process = spawn_link(fn -> relay(me, :cc) end)
      _ = register_role(cc_process, sid, :cc_process)

      {:ok, _peer} =
        GenServer.start_link(Esr.Entity.FeishuChatProxy, %{
          session_id: sid,
          chat_id: "oc_unsup",
          thread_id: "",
          proxy_ctx: %{}
        })

      # claude_code does NOT support image inbound.
      PluginRegistry.register("claude_code", %{inbound: [:file], outbound: []})

      envelope = %{
        "source" => "esr://default@localhost/adapters/feishu/#{instance_id}",
        "principal_id" => "ou_unsup_user",
        "payload" => %{
          "event_type" => "msg_received",
          "args" => %{
            "chat_id" => "oc_unsup",
            "msg_type" => "image",
            "msg_id" => "om_unsup_1",
            "sender_id" => "ou_unsup_user"
          }
        }
      }

      [{fcp_pid, _}] = Registry.lookup(Esr.Entity.Registry, "thread:" <> sid)
      send(fcp_pid, {:feishu_inbound, envelope})

      # FAA broadcasts the DM directive on the adapter topic.
      # CapGuard.media_unsupported_dm -> FAA receives {:outbound, reply}
      # -> FAA wraps as directive -> broadcast on adapter:feishu/<instance_id>.
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "envelope",
                       payload: %{
                         "kind" => "directive",
                         "payload" => %{"action" => "send_message"}
                       }
                     },
                     2_000

      # Nothing forwarded to cc_process.
      refute_receive {:relay, :cc, _}, 200
    end

    test "drops unknown msg_type (e.g. interactive) with log warning" do
      import ExUnit.CaptureLog

      me = self()
      sid = "s_interactive_#{System.unique_integer([:positive])}"

      cc_process = spawn_link(fn -> relay(me, :cc) end)
      _ = register_role(cc_process, sid, :cc_process)

      {:ok, _peer} =
        GenServer.start_link(Esr.Entity.FeishuChatProxy, %{
          session_id: sid,
          chat_id: "oc_inter",
          thread_id: "",
          proxy_ctx: %{}
        })

      original_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: original_level) end)

      log =
        capture_log(fn ->
          [{fcp_pid, _}] = Registry.lookup(Esr.Entity.Registry, "thread:" <> sid)

          send(fcp_pid, {:feishu_inbound, %{
            "payload" => %{
              "event_type" => "msg_received",
              "args" => %{
                "chat_id" => "oc_inter",
                "msg_type" => "interactive",
                "msg_id" => "om_inter_1"
              }
            }
          }})

          Process.sleep(50)
        end)

      assert log =~ "unsupported msg_type"
      refute_receive {:relay, :cc, _}, 100
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

      {:ok, state} = Esr.Entity.FeishuChatProxy.init(args)
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

      {:ok, state} = Esr.Entity.FeishuChatProxy.init(args)
      assert Map.get(state, "channel_adapter") == "feishu"
    end
  end

  # Trivial relay: forward every received message to the test pid, tagged
  # with a label so tests can distinguish cc_process vs feishu_app_proxy.
  defp relay(reply_to, label) do
    receive do
      # M-2.1 test seam: register self() under (sid, role) so FCP's
      # ActorQuery.list_by_role resolves to this relay.
      {:m2_register_role, replier, actor_id, session_id, role} ->
        :ok =
          Esr.Entity.Registry.register_attrs(actor_id, %{
            session_id: session_id,
            name: "test-#{role}-#{actor_id}",
            role: role
          })

        send(replier, {:m2_role_registered, actor_id})
        relay(reply_to, label)

      msg ->
        send(reply_to, {:relay, label, msg})
        relay(reply_to, label)
    end
  end

  # M-2.1: register `pid` in Index 3 under (session_id, role). Used by
  # tests that exercise FCP's ActorQuery-based role lookups.
  defp register_role(pid, session_id, role) do
    actor_id = "test-actor-#{session_id}-#{role}-#{System.unique_integer([:positive])}"
    parent = self()
    send(pid, {:m2_register_role, parent, actor_id, session_id, role})

    receive do
      {:m2_role_registered, ^actor_id} -> actor_id
    after
      1000 -> raise "register_role timed out for #{inspect(pid)} sid=#{session_id} role=#{role}"
    end
  end

  # Task 2.4: relay variant for the feishu_app_proxy role that also
  # publishes a directive_ack on PubSub when it receives a directive
  # outbound. This allows FCP's synchronous build_directive_fn/1 to
  # complete without timing out in tests.
  #
  # Usage: send {:set_ack_uri, uri} before triggering inbound to configure
  # the URI returned in the fake ack payload.
  defp relay_with_directive_ack(reply_to, ack_uri \\ nil) do
    receive do
      {:set_ack_uri, uri} ->
        relay_with_directive_ack(reply_to, uri)

      {:m2_register_role, replier, actor_id, session_id, role} ->
        :ok =
          Esr.Entity.Registry.register_attrs(actor_id, %{
            session_id: session_id,
            name: "test-#{role}-#{actor_id}",
            role: role
          })

        send(replier, {:m2_role_registered, actor_id})
        relay_with_directive_ack(reply_to, ack_uri)

      {:outbound, %{"kind" => "directive", "id" => id} = directive} = msg ->
        send(reply_to, {:relay, :app, msg})

        # Publish directive_ack so FCP's blocking receive resolves.
        uri =
          ack_uri ||
            "esr://test@localhost:4001/resources/image/" <>
              String.duplicate("a", 64) <> ".bin"

        if Process.whereis(EsrWeb.PubSub) do
          Phoenix.PubSub.broadcast(
            EsrWeb.PubSub,
            "directive_ack:" <> id,
            {:directive_ack,
             %{
               "id" => id,
               "payload" => %{
                 "ok" => true,
                 "result" => %{
                   "uri" => uri,
                   "sha256" => String.duplicate("a", 64),
                   "path" => "/tmp/fake_media"
                 }
               }
             }}
          )
        end

        relay_with_directive_ack(reply_to, ack_uri)

      msg ->
        send(reply_to, {:relay, :app, msg})
        relay_with_directive_ack(reply_to, ack_uri)
    end
  end
end
