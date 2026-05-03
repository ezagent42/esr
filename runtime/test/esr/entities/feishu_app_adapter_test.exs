defmodule Esr.Entities.FeishuAppAdapterTest do
  use ExUnit.Case, async: false

  alias Esr.Entities.FeishuAppAdapter

  setup do
    # Drift from expansion doc: both `Esr.SessionRegistry` (via 4d) and
    # `Esr.Scope.Admin.Process` (via P2-9's Scope.Admin) are now started
    # at app boot, so a redundant `start_supervised!` would crash with
    # :already_started. Reuse the app-level processes.
    assert is_pid(Process.whereis(Esr.SessionRegistry))
    assert is_pid(Process.whereis(Esr.Scope.Admin.Process))
    # No `name:` on the supervisor — a hard-coded atom collided across
    # tests when a previous run's DynamicSupervisor hadn't fully torn
    # down yet (PR-5 os_cleanup flake). Thread the pid via ctx instead.
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

    on_exit(fn -> if Process.alive?(sup), do: Process.exit(sup, :shutdown) end)
    {:ok, sup: sup}
  end

  test "start_link registers the adapter as :feishu_app_adapter_<instance_id> in Scope.Admin.Process",
       %{sup: sup} do
    {:ok, pid} =
      DynamicSupervisor.start_child(
        sup,
        {FeishuAppAdapter, %{instance_id: "inst_test123", neighbors: [], proxy_ctx: %{}}}
      )

    assert Process.alive?(pid)
    {:ok, ^pid} = Esr.Scope.Admin.Process.admin_peer(:feishu_app_adapter_inst_test123)
  end

  test "inbound envelope with chat+thread routes to the matching FeishuChatProxy via SessionRegistry",
       %{sup: sup} do
    # Arrange: register a fake session with a test-owned "proxy pid"
    test_pid = self()

    :ok =
      Esr.SessionRegistry.register_session(
        "session-abc",
        # PR-A T1: registry key is (chat_id, app_id, thread_id). Pre-PR-A
        # envelopes (no args["app_id"]) fall back to state.instance_id —
        # so the registry app_id MUST equal the adapter's instance_id
        # for the legacy path to resolve.
        %{chat_id: "oc_xyz", app_id: "inst_test456", thread_id: "om_123"},
        %{feishu_chat_proxy: test_pid}
      )

    {:ok, pid} =
      DynamicSupervisor.start_child(
        sup,
        {FeishuAppAdapter, %{instance_id: "inst_test456", neighbors: [], proxy_ctx: %{}}}
      )

    # Real adapter envelope shape (see py/src/esr/ipc/envelope.py make_event).
    envelope = %{
      "payload" => %{
        "event_type" => "msg_received",
        "args" => %{
          "chat_id" => "oc_xyz",
          "thread_id" => "om_123",
          "content" => "hello"
        }
      }
    }

    send(pid, {:inbound_event, envelope})
    assert_receive {:feishu_inbound, ^envelope}, 500
  end

  test "PR-A T1: handle_upstream uses args[app_id] for registry lookup, falls back to state.instance_id",
       %{sup: sup} do
    test_pid = self()

    # Arrange: register a session keyed under app_id "feishu_DEV"
    :ok =
      Esr.SessionRegistry.register_session(
        "S_PRA_FAA",
        %{chat_id: "oc_PRA", app_id: "feishu_DEV", thread_id: ""},
        %{feishu_chat_proxy: test_pid}
      )

    # Adapter's instance_id is intentionally a *different* string than
    # the registry app_id, so the only way the lookup hits is via
    # args["app_id"] from the envelope (post-PR-A wire shape).
    {:ok, pid_args_path} =
      DynamicSupervisor.start_child(
        sup,
        {FeishuAppAdapter, %{instance_id: "feishu_OTHER", neighbors: [], proxy_ctx: %{}}}
      )

    env_with_app_id = %{
      "payload" => %{
        "event_type" => "msg_received",
        "args" => %{
          "chat_id" => "oc_PRA",
          "app_id" => "feishu_DEV",
          "thread_id" => "",
          "content" => "hi"
        }
      }
    }

    send(pid_args_path, {:inbound_event, env_with_app_id})
    assert_receive {:feishu_inbound, ^env_with_app_id}, 500

    # Now prove the legacy fallback: envelope WITHOUT args["app_id"],
    # adapter's instance_id matches the registry app_id. The lookup
    # must succeed via the state.instance_id branch.
    {:ok, pid_fallback} =
      DynamicSupervisor.start_child(
        sup,
        {FeishuAppAdapter, %{instance_id: "feishu_DEV", neighbors: [], proxy_ctx: %{}}}
      )

    env_without_app_id = %{
      "payload" => %{
        "event_type" => "msg_received",
        "args" => %{
          "chat_id" => "oc_PRA",
          "thread_id" => "",
          "content" => "hi-legacy"
        }
      }
    }

    send(pid_fallback, {:inbound_event, env_without_app_id})
    assert_receive {:feishu_inbound, ^env_without_app_id}, 500

    Esr.SessionRegistry.unregister_session("S_PRA_FAA")
  end

  test "registration key is instance_id, not Feishu-platform app_id (PR-9 T10)",
       %{sup: sup} do
    # In production the operator-chosen instance name in adapters.yaml
    # (e.g. "main_bot", "feishu_app_e2e-mock") is distinct from the
    # Feishu-platform app_id (e.g. "cli_a9563cc03d399cc9"). The Python
    # adapter_runner joins `adapter:feishu/<instance_id>`, so the Elixir
    # peer's Scope.Admin registration MUST be keyed on instance_id so
    # adapter_channel.forward_to_new_chain/2 can find it.
    {:ok, pid} =
      DynamicSupervisor.start_child(
        sup,
        {FeishuAppAdapter,
         %{
           instance_id: "main_bot",
           app_id: "cli_a9563cc03d399cc9",
           neighbors: [],
           proxy_ctx: %{}
         }}
      )

    # Registered under instance_id.
    assert {:ok, ^pid} = Esr.Scope.Admin.Process.admin_peer(:feishu_app_adapter_main_bot)

    # NOT registered under the Feishu-platform app_id.
    assert :error = Esr.Scope.Admin.Process.admin_peer(:feishu_app_adapter_cli_a9563cc03d399cc9)

    # Peer state retains the real app_id for Feishu API calls.
    assert %{app_id: "cli_a9563cc03d399cc9", instance_id: "main_bot"} = :sys.get_state(pid)
  end

  test "inbound envelope with no matching session emits :new_chat_thread event", %{sup: sup} do
    # With no SessionRegistry entry for (chat_id, thread_id),
    # FeishuAppAdapter broadcasts a :new_chat_thread event on the
    # `session_router` PubSub topic for Scope.Router to consume.
    # P3-7: topic is `session_router` (was "new_chat_thread"); tuple
    # order is `{:new_chat_thread, app_id, chat_id, thread_id, envelope}`
    # (app_id first — FeishuAppAdapter owns the wiring).
    #
    # PR-N 2026-04-28: FAA peer now intercepts unbound chats (no
    # workspaces.yaml entry) and DM-guides instead of broadcasting.
    # Register a workspace for (oc_new, inst_nomatch) so this test
    # exercises the broadcast path; the unbound-chat path has its own
    # test below.
    :ok =
      Esr.Workspaces.Registry.put(%Esr.Workspaces.Registry.Workspace{
        name: "ws_for_new_chat_thread_test",
        owner: nil,
        chats: [%{"chat_id" => "oc_new", "app_id" => "inst_nomatch", "kind" => "dm"}]
      })

    :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "session_router")

    {:ok, pid} =
      DynamicSupervisor.start_child(
        sup,
        {FeishuAppAdapter, %{instance_id: "inst_nomatch", neighbors: [], proxy_ctx: %{}}}
      )

    envelope = %{
      "payload" => %{
        "event_type" => "msg_received",
        "args" => %{
          "chat_id" => "oc_new",
          "thread_id" => "om_new",
          "content" => "first message"
        }
      }
    }

    send(pid, {:inbound_event, envelope})

    # Tuple's second slot is the Phoenix routing key (instance_id).
    assert_receive {:new_chat_thread, "inst_nomatch", "oc_new", "om_new", ^envelope}, 500
  end

  describe "PR-N: unbound-chat guide DM" do
    test "inbound for chat with no workspace binding emits guide DM, drops broadcast",
         %{sup: sup} do
      :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "session_router")
      :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "adapter:feishu/inst_unbound")

      {:ok, pid} =
        DynamicSupervisor.start_child(
          sup,
          {FeishuAppAdapter,
           %{instance_id: "inst_unbound", neighbors: [], proxy_ctx: %{}}}
        )

      envelope = %{
        "payload" => %{
          "event_type" => "msg_received",
          "args" => %{
            "chat_id" => "oc_unbound_chat",
            "thread_id" => "",
            "content" => "first contact"
          }
        }
      }

      send(pid, {:inbound_event, envelope})

      # FAA's handle_downstream wraps the {:outbound, %{kind:"reply",...}}
      # into a directive envelope before broadcasting on
      # `adapter:feishu/<instance_id>`. Content lands at
      # payload.payload.args.content (not args.text).
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "envelope",
                       payload: %{
                         "kind" => "directive",
                         "payload" => %{
                           "action" => "send_message",
                           "args" => %{"chat_id" => "oc_unbound_chat", "content" => content}
                         }
                       }
                     },
                     500

      assert content =~ "workspace add"
      assert content =~ "oc_unbound_chat"
      assert content =~ "inst_unbound"

      # And the new_chat_thread broadcast must NOT happen — we're
      # dropping the inbound rather than spinning up a session against
      # an unconfigured chat.
      refute_receive {:new_chat_thread, _, _, _, _}, 200
    end

    test "second inbound from same unbound chat is rate-limited (no second DM)",
         %{sup: sup} do
      :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "adapter:feishu/inst_ratelimit")

      {:ok, pid} =
        DynamicSupervisor.start_child(
          sup,
          {FeishuAppAdapter,
           %{instance_id: "inst_ratelimit", neighbors: [], proxy_ctx: %{}}}
        )

      envelope = fn n ->
        %{
          "payload" => %{
            "event_type" => "msg_received",
            "args" => %{"chat_id" => "oc_spam", "thread_id" => "", "content" => "msg #{n}"}
          }
        }
      end

      send(pid, {:inbound_event, envelope.(1)})
      send(pid, {:inbound_event, envelope.(2)})
      send(pid, {:inbound_event, envelope.(3)})

      # Exactly one DM directive should have been broadcast.
      assert_receive %Phoenix.Socket.Broadcast{event: "envelope", payload: %{"kind" => "directive"}},
                     500

      refute_receive %Phoenix.Socket.Broadcast{event: "envelope", payload: %{"kind" => "directive"}},
                     200
    end
  end

  describe "PR-21i: unbound-user guide DM" do
    setup do
      # Ensure Esr.Users.Registry is up + empty for these tests.
      if Process.whereis(Esr.Users.Registry) == nil do
        start_supervised!(Esr.Users.Registry)
      end

      Esr.Users.Registry.load_snapshot(%{})
      :ok
    end

    test "chat-bound + user-unbound emits user-guide DM", %{sup: sup} do
      # Pre: register a workspace bound to (oc_user_test, inst_user_guide)
      :ok =
        Esr.Workspaces.Registry.put(%Esr.Workspaces.Registry.Workspace{
          name: "ws_for_user_guide_test",
          owner: "linyilun",
          chats: [
            %{"chat_id" => "oc_user_test", "app_id" => "inst_user_guide", "kind" => "dm"}
          ]
        })

      :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "adapter:feishu/inst_user_guide")
      :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "session_router")

      {:ok, pid} =
        DynamicSupervisor.start_child(
          sup,
          {FeishuAppAdapter,
           %{instance_id: "inst_user_guide", neighbors: [], proxy_ctx: %{}}}
        )

      envelope = %{
        # PR-21i: top-level user_id (Feishu envelope shape)
        "user_id" => "ou_unbound_xyz",
        "payload" => %{
          "event_type" => "msg_received",
          "args" => %{
            "chat_id" => "oc_user_test",
            "app_id" => "inst_user_guide",
            "thread_id" => "",
            "content" => "hello"
          }
        }
      }

      send(pid, {:inbound_event, envelope})

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "envelope",
                       payload: %{
                         "kind" => "directive",
                         "payload" => %{
                           "action" => "send_message",
                           "args" => %{"chat_id" => "oc_user_test", "content" => content}
                         }
                       }
                     },
                     500

      # DM mentions the user-bind command + carries the open_id verbatim
      assert content =~ "user bind-feishu"
      assert content =~ "ou_unbound_xyz"

      # No new_chat_thread broadcast — inbound dropped at user-guide gate
      refute_receive {:new_chat_thread, _, _, _, _}, 200
    end

    test "chat-bound + user-bound proceeds normally (no user-guide DM)",
         %{sup: sup} do
      # Bind ou_known_xyz to linyilun
      :ok =
        Esr.Users.Registry.load_snapshot(%{
          "linyilun" => %Esr.Users.Registry.User{
            username: "linyilun",
            feishu_ids: ["ou_known_xyz"]
          }
        })

      :ok =
        Esr.Workspaces.Registry.put(%Esr.Workspaces.Registry.Workspace{
          name: "ws_for_user_bound_test",
          owner: "linyilun",
          chats: [
            %{"chat_id" => "oc_bound", "app_id" => "inst_user_bound", "kind" => "dm"}
          ]
        })

      :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "session_router")

      {:ok, pid} =
        DynamicSupervisor.start_child(
          sup,
          {FeishuAppAdapter,
           %{instance_id: "inst_user_bound", neighbors: [], proxy_ctx: %{}}}
        )

      envelope = %{
        "user_id" => "ou_known_xyz",
        "payload" => %{
          "event_type" => "msg_received",
          "args" => %{
            "chat_id" => "oc_bound",
            "app_id" => "inst_user_bound",
            "thread_id" => "om_t1",
            "content" => "hello"
          }
        }
      }

      send(pid, {:inbound_event, envelope})

      # Should reach session-routing path (broadcast new_chat_thread since
      # no live session exists) — NOT trapped by user-guide gate.
      assert_receive {:new_chat_thread, "inst_user_bound", "oc_bound", "om_t1", ^envelope}, 500
    end

    test "chat unbound: chat-guide DM takes precedence (user-guide does not pile on)",
         %{sup: sup} do
      :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "adapter:feishu/inst_chat_first")

      {:ok, pid} =
        DynamicSupervisor.start_child(
          sup,
          {FeishuAppAdapter,
           %{instance_id: "inst_chat_first", neighbors: [], proxy_ctx: %{}}}
        )

      envelope = %{
        "user_id" => "ou_unbound_too",
        "payload" => %{
          "event_type" => "msg_received",
          "args" => %{
            "chat_id" => "oc_chat_unbound",
            "app_id" => "inst_chat_first",
            "thread_id" => "",
            "content" => "hello"
          }
        }
      }

      send(pid, {:inbound_event, envelope})

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "envelope",
                       payload: %{
                         "payload" => %{
                           "args" => %{"content" => content}
                         }
                       }
                     },
                     500

      # The chat-guide DM mentions `workspace add`; the user-guide DM
      # mentions `user bind-feishu`. We expect the chat one only.
      assert content =~ "workspace add"
      refute content =~ "user bind-feishu"

      # No second DM stacked on top
      refute_receive %Phoenix.Socket.Broadcast{event: "envelope"}, 200
    end

    test "second inbound from same unbound user is rate-limited", %{sup: sup} do
      :ok =
        Esr.Workspaces.Registry.put(%Esr.Workspaces.Registry.Workspace{
          name: "ws_for_user_ratelimit",
          owner: "linyilun",
          chats: [
            %{"chat_id" => "oc_ratelimit", "app_id" => "inst_user_ratelimit", "kind" => "dm"}
          ]
        })

      :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "adapter:feishu/inst_user_ratelimit")

      {:ok, pid} =
        DynamicSupervisor.start_child(
          sup,
          {FeishuAppAdapter,
           %{instance_id: "inst_user_ratelimit", neighbors: [], proxy_ctx: %{}}}
        )

      envelope = fn n ->
        %{
          "user_id" => "ou_spam",
          "payload" => %{
            "event_type" => "msg_received",
            "args" => %{
              "chat_id" => "oc_ratelimit",
              "app_id" => "inst_user_ratelimit",
              "thread_id" => "",
              "content" => "msg #{n}"
            }
          }
        }
      end

      send(pid, {:inbound_event, envelope.(1)})
      send(pid, {:inbound_event, envelope.(2)})
      send(pid, {:inbound_event, envelope.(3)})

      # Exactly one user-guide DM directive
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "envelope",
                       payload: %{
                         "payload" => %{"args" => %{"content" => content}}
                       }
                     },
                     500

      assert content =~ "user bind-feishu"

      refute_receive %Phoenix.Socket.Broadcast{event: "envelope"}, 200
    end
  end

  describe "PR-21κ slash dispatch (yaml-driven)" do
    # PR-21κ Phase 4: any inbound text starting with `/` is forwarded
    # to `Esr.Entities.SlashHandler` via `dispatch/3`. The pre-PR-21κ
    # tests asserted the FAA's inline `/help` / `/whoami` / `/doctor`
    # text replies — those now live in the command modules and are
    # exercised by their own unit tests. What this describe block
    # cares about: the FAA-side wiring, i.e. "slash → dispatch cast".
    #
    # We register a fake SlashHandler under the same name the
    # production handler uses, so `Esr.Entities.SlashHandler.dispatch/3`'s
    # `GenServer.cast(__MODULE__, ...)` lands in our test mailbox.

    setup do
      test_self = self()

      slash_pid =
        spawn_link(fn ->
          loop = fn loop ->
            receive do
              msg ->
                send(test_self, {:slash_received, msg})
                loop.(loop)
            end
          end

          loop.(loop)
        end)

      # PR-21κ Phase 6: production `dispatch/3` resolves the slash
      # handler via `Esr.Scope.Admin.Process.slash_handler_ref/0`.
      # Override the registration with our recording stub so the FAA's
      # cast lands in the test mailbox. on_exit tries to restart the
      # production slash_handler via the Scope.Admin bootstrap helper
      # — re-registering the dead test pid would leave the registry
      # broken for subsequent tests.
      :ok = Esr.Scope.Admin.Process.register_admin_peer(:slash_handler, slash_pid)

      on_exit(fn ->
        # Re-bootstrap the production handler so other tests find a
        # live pid under :slash_handler. Idempotent under the production
        # supervisor; safely no-op when supervisor_test has torn it down
        # (try/rescue covers the GenServer.call to a dead supervisor).
        try do
          Esr.Scope.Admin.bootstrap_slash_handler()
        catch
          :exit, _ -> :ok
        end
      end)

      :ok
    end

    for slash <- ["/help", "/whoami", "/doctor", "/new-workspace my-ws"] do
      @slash slash
      test "FAA forwards #{@slash} to SlashHandler.dispatch/3", %{sup: sup} do
        instance = "inst_dispatch_#{System.unique_integer([:positive])}"

        {:ok, pid} =
          DynamicSupervisor.start_child(
            sup,
            {FeishuAppAdapter, %{instance_id: instance, neighbors: [], proxy_ctx: %{}}}
          )

        envelope = %{
          "user_id" => "ou_dispatch_user",
          "principal_id" => "ou_dispatch_user",
          "payload" => %{
            "event_type" => "msg_received",
            "args" => %{
              "chat_id" => "oc_dispatch_test",
              "app_id" => instance,
              "thread_id" => "",
              "content" => @slash
            }
          }
        }

        send(pid, {:inbound_event, envelope})

        # GenServer.cast lands in the registered slash_pid as
        # {:"$gen_cast", {:dispatch, envelope, reply_to, ref}}.
        assert_receive {:slash_received,
                        {:"$gen_cast",
                         {:dispatch, dispatched_envelope, ^pid, ref}}},
                       500

        assert is_reference(ref)
        # FAA threads the original text into payload.text for the dispatch.
        assert get_in(dispatched_envelope, ["payload", "text"]) == @slash
      end
    end

    test "FAA delivers the SlashHandler reply as a chat DM keyed by ref", %{sup: sup} do
      instance = "inst_dispatch_reply_#{System.unique_integer([:positive])}"
      :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "adapter:feishu/#{instance}")

      {:ok, pid} =
        DynamicSupervisor.start_child(
          sup,
          {FeishuAppAdapter, %{instance_id: instance, neighbors: [], proxy_ctx: %{}}}
        )

      envelope = %{
        "user_id" => "ou_reply_user",
        "principal_id" => "ou_reply_user",
        "payload" => %{
          "event_type" => "msg_received",
          "args" => %{
            "chat_id" => "oc_reply_chat",
            "app_id" => instance,
            "thread_id" => "",
            "content" => "/help"
          }
        }
      }

      send(pid, {:inbound_event, envelope})

      assert_receive {:slash_received,
                      {:"$gen_cast", {:dispatch, _env, ^pid, ref}}},
                     500

      # Simulate SlashHandler's reply
      send(pid, {:reply, "test help text", ref})

      # FAA should DM the reply on the adapter:feishu/<instance> topic
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "envelope",
                       payload: %{
                         "kind" => "directive",
                         "payload" => %{
                           "args" => %{"chat_id" => "oc_reply_chat", "content" => content}
                         }
                       }
                     },
                     500

      assert content == "test help text"
    end
  end

  describe "PR-21λ universal react / un_react" do
    setup %{sup: sup} do
      instance = "inst_react_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        DynamicSupervisor.start_child(
          sup,
          {FeishuAppAdapter, %{instance_id: instance, neighbors: [], proxy_ctx: %{}}}
        )

      :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "adapter:feishu/#{instance}")
      {:ok, peer: pid, instance: instance}
    end

    test "msg_received inbound emits Typing react with the message_id", %{peer: peer} do
      envelope = %{
        "user_id" => "ou_react_user",
        "principal_id" => "ou_react_user",
        "payload" => %{
          "event_type" => "msg_received",
          "args" => %{
            "chat_id" => "oc_react",
            "content" => "hello",
            "message_id" => "om_msg_42"
          }
        }
      }

      send(peer, {:inbound_event, envelope})

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "envelope",
                       payload: %{
                         "kind" => "directive",
                         "payload" => %{
                           "action" => "react",
                           "args" => %{"msg_id" => "om_msg_42", "emoji_type" => "Typing"}
                         }
                       }
                     },
                     500
    end

    test "non-msg_received envelope (e.g. event_type empty) does NOT emit react", %{peer: peer} do
      envelope = %{
        "principal_id" => "ou_x",
        "payload" => %{
          "event_type" => "system_notify",
          "args" => %{"message_id" => "om_sys_1"}
        }
      }

      send(peer, {:inbound_event, envelope})

      refute_receive %Phoenix.Socket.Broadcast{
                       payload: %{"payload" => %{"action" => "react"}}
                     },
                     200
    end

    test "downstream reply with reply_to_message_id un_reacts the tracked react",
         %{peer: peer} do
      # First fire an inbound to register the react.
      inbound = %{
        "principal_id" => "ou_x",
        "payload" => %{
          "event_type" => "msg_received",
          "args" => %{"chat_id" => "oc_x", "content" => "hi", "message_id" => "om_track"}
        }
      }

      send(peer, {:inbound_event, inbound})

      assert_receive %Phoenix.Socket.Broadcast{
                       payload: %{
                         "payload" => %{
                           "action" => "react",
                           "args" => %{"msg_id" => "om_track"}
                         }
                       }
                     },
                     500

      # Now simulate FCP's CC-reply outbound carrying reply_to_message_id.
      send(
        peer,
        {:outbound,
         %{
           "kind" => "reply",
           "args" => %{
             "chat_id" => "oc_x",
             "text" => "done",
             "reply_to_message_id" => "om_track"
           }
         }}
      )

      # FAA should emit un_react first (matching the tracked Typing),
      # then the reply send_message directive.
      assert_receive %Phoenix.Socket.Broadcast{
                       payload: %{
                         "payload" => %{
                           "action" => "un_react",
                           "args" => %{"msg_id" => "om_track", "emoji_type" => "Typing"}
                         }
                       }
                     },
                     500

      assert_receive %Phoenix.Socket.Broadcast{
                       payload: %{
                         "payload" => %{
                           "action" => "send_message",
                           "args" => %{"chat_id" => "oc_x", "content" => "done"}
                         }
                       }
                     },
                     500
    end

    test "downstream reply without reply_to_message_id does NOT un_react", %{peer: peer} do
      send(
        peer,
        {:outbound,
         %{"kind" => "reply", "args" => %{"chat_id" => "oc_x", "text" => "proactive"}}}
      )

      assert_receive %Phoenix.Socket.Broadcast{
                       payload: %{"payload" => %{"action" => "send_message"}}
                     },
                     500

      refute_receive %Phoenix.Socket.Broadcast{
                       payload: %{"payload" => %{"action" => "un_react"}}
                     },
                     100
    end
  end

  describe "handle_downstream wrap_as_directive/2 (PR-9 T10/T11b)" do
    # The downstream path broadcasts on `adapter:feishu/<instance_id>` with
    # event="envelope" and a *directive*-shaped payload. Subscribe to the
    # PubSub topic, fire the peer, and assert the directive shape.
    setup %{sup: sup} do
      instance_id = "inst_T11b5_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        DynamicSupervisor.start_child(
          sup,
          {FeishuAppAdapter, %{instance_id: instance_id, neighbors: [], proxy_ctx: %{}}}
        )

      :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "adapter:feishu/#{instance_id}")
      {:ok, peer: pid, instance_id: instance_id}
    end

    test "send_file pass-through to directive action=send_file (T11b.5)", %{peer: peer} do
      envelope = %{
        "kind" => "send_file",
        "args" => %{"chat_id" => "oc_target", "file_path" => "/tmp/foo.txt"}
      }

      send(peer, {:outbound, envelope})

      assert_receive %Phoenix.Socket.Broadcast{
        event: "envelope",
        payload: %{
          "kind" => "directive",
          "payload" => %{
            "adapter" => "feishu",
            "action" => "send_file",
            "args" => %{"chat_id" => "oc_target", "file_path" => "/tmp/foo.txt"}
          }
        }
      }, 500
    end

    test "reply maps to directive action=send_message with text→content rename", %{peer: peer} do
      envelope = %{
        "kind" => "reply",
        "args" => %{"chat_id" => "oc_target", "text" => "ack"}
      }

      send(peer, {:outbound, envelope})

      assert_receive %Phoenix.Socket.Broadcast{
        event: "envelope",
        payload: %{
          "payload" => %{
            "action" => "send_message",
            "args" => %{"chat_id" => "oc_target", "content" => "ack"}
          }
        }
      }, 500
    end

    test "react passes through unchanged", %{peer: peer} do
      envelope = %{
        "kind" => "react",
        "args" => %{"msg_id" => "om_foo", "emoji_type" => "EYES"}
      }

      send(peer, {:outbound, envelope})

      assert_receive %Phoenix.Socket.Broadcast{
        event: "envelope",
        payload: %{
          "payload" => %{
            "action" => "react",
            "args" => %{"msg_id" => "om_foo", "emoji_type" => "EYES"}
          }
        }
      }, 500
    end
  end
end
