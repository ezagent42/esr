defmodule Esr.Entity.FeishuChatProxyCrossAppTest do
  @moduledoc """
  PR-A T4: cross-app reply dispatch + authorization tests.

  Spawns two fake FeishuAppAdapter peers (one per app), points FCP's
  state at app_dev as its home, and fires a reply tool_invoke
  targeting app_kanban. Asserts the directive lands in the
  correct adapter's mailbox.

  Test seams used:
    * `Esr.Resource.Capability.Grants.load_snapshot/1` — pattern from
      runtime/test/esr/capabilities_has_all_test.exs.
    * `Esr.Resource.Workspace.Registry.put/1` with %Workspace{}.
    * `Esr.Entity.Registry.register/2` only registers `self()`, hence the
      relay registers itself before entering its receive loop.
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Esr.Entity.FeishuChatProxy

  setup do
    # Snapshot prior global state so each test cleans up after itself.
    prior_grants =
      try do
        :ets.tab2list(:esr_capabilities_grants) |> Map.new()
      rescue
        _ -> %{}
      end

    on_exit(fn ->
      Esr.Resource.Capability.Grants.load_snapshot(prior_grants)

      :ets.delete(:esr_workspaces, "ws_kanban")
      :ets.delete(:esr_workspaces, "ws_unknown")
    end)

    parent = self()

    # M-2.1: relays register in Index 1 (Entity.Registry — used by FCP's
    # cross-app dispatch via `Registry.lookup(..., "feishu_app_adapter_<app>")`).
    # The home-app reply path uses `ActorQuery.list_by_role/2` (Index 3);
    # tests that exercise that path call `register_role/3` (helper below)
    # to bind the dev relay into their session's role index.
    spawn_relay = fn label, registered_name ->
      spawn_link(fn ->
        {:ok, _} = Esr.Entity.Registry.register(registered_name, self())
        send(parent, {:registered, label})
        relay_loop(parent, label)
      end)
    end

    dev_pid = spawn_relay.(:dev, "feishu_app_adapter_feishu_dev")
    kanban_pid = spawn_relay.(:kanban, "feishu_app_adapter_feishu_kanban")
    assert_receive {:registered, :dev}, 500
    assert_receive {:registered, :kanban}, 500

    %{dev_pid: dev_pid, kanban_pid: kanban_pid}
  end

  # M-2.1 helper: register `pid` in the role index under
  # `(session_id, :feishu_app_proxy)` so FCP's home-app branch
  # (ActorQuery.list_by_role) resolves it. Returns the actor_id used so
  # tests can deregister if needed.
  defp register_role(pid, session_id, role) do
    actor_id = "test-faa-#{session_id}-#{System.unique_integer([:positive])}"

    # register_attrs registers `self()`, so we must run it from the
    # target pid. Send a sync message to do so.
    parent = self()

    Process.send(
      pid,
      {:m2_register_role, parent, actor_id, session_id, role},
      []
    )

    receive do
      {:m2_role_registered, ^actor_id} -> actor_id
    after
      1000 -> raise "register_role timed out for #{inspect(pid)}"
    end
  end

  defp relay_loop(parent, label) do
    receive do
      # M-2.1 test seam: register self() in Index 3 for the given session_id.
      # Used by tests that need the home-app reply (ActorQuery.list_by_role)
      # branch to resolve to this relay.
      {:m2_register_role, replier, actor_id, session_id, role} ->
        :ok =
          Esr.Entity.Registry.register_attrs(actor_id, %{
            session_id: session_id,
            name: "faa-test-#{session_id}-#{actor_id}",
            role: role
          })

        send(replier, {:m2_role_registered, actor_id})
        relay_loop(parent, label)

      msg ->
        send(parent, {:relay, label, msg})
        relay_loop(parent, label)
    end
  end

  # Helper to seed grants for a principal — uses the same load_snapshot
  # pattern as runtime/test/esr/capabilities_has_all_test.exs.
  defp grant_caps(principal_id, caps) do
    Esr.Resource.Capability.Grants.load_snapshot(%{principal_id => caps})
  end

  # Helper to seed (chat_id, app_id) → workspace_name. Uses
  # Workspaces.Registry.put/1 with the existing Workspace struct
  # at Esr.Resource.Workspace.Registry.Workspace (note: nested under Registry,
  # not at Esr.Resource.Workspace.Workspace).
  defp put_chat_in_workspace(ws_name, chat_id, app_id) do
    Esr.Resource.Workspace.Registry.put(%Esr.Resource.Workspace.Registry.Workspace{
      name: ws_name,
      owner: nil,
      start_cmd: "",
      role: "dev",
      chats: [%{"chat_id" => chat_id, "app_id" => app_id, "kind" => "dm"}],
      env: %{}
    })
  end

  # FCP's init/1 fetches :session_id, :chat_id, :thread_id and reads
  # :neighbors, :proxy_ctx, :app_id, :principal_id, :pending_reacts.
  # Build a complete arg map for GenServer.start_link.
  defp fcp_args(overrides) do
    Map.merge(
      %{
        session_id: "S_PRA4",
        chat_id: "oc_dev",
        thread_id: "",
        app_id: "feishu_dev",
        principal_id: "ou_admin",
        neighbors: [],
        proxy_ctx: %{},
        pending_reacts: %{}
      },
      overrides
    )
  end

  test "home-app reply routes to home FAA (no cross-app branch)", ctx do
    # M-2.1: home-app reply path goes through ActorQuery.list_by_role.
    # Register the dev relay in the role index for this test session.
    _ = register_role(ctx.dev_pid, "S_PRA4_HOME", :feishu_app_proxy)

    {:ok, peer} =
      GenServer.start_link(
        FeishuChatProxy,
        fcp_args(%{
          session_id: "S_PRA4_HOME"
        })
      )

    send(
      peer,
      {:tool_invoke, "req-home", "reply",
       %{"chat_id" => "oc_dev", "app_id" => "feishu_dev", "text" => "ack"}, self(),
       "ou_admin"}
    )

    assert_receive {:relay, :dev,
                    {:outbound, %{"kind" => "reply", "args" => %{"text" => "ack"}}}},
                   500

    assert_receive {:push_envelope, %{"req_id" => "req-home", "ok" => true}}, 500
    refute_receive {:relay, :kanban, _}, 200
  end

  test "cross-app reply routes to target FAA when authorized", ctx do
    grant_caps("ou_admin", ["workspace:ws_kanban/msg.send"])
    put_chat_in_workspace("ws_kanban", "oc_kanban", "feishu_kanban")

    {:ok, peer} =
      GenServer.start_link(
        FeishuChatProxy,
        fcp_args(%{
          session_id: "S_PRA4_X",
          neighbors: [feishu_app_proxy: ctx.dev_pid]
        })
      )

    send(
      peer,
      {:tool_invoke, "req-x", "reply",
       %{"chat_id" => "oc_kanban", "app_id" => "feishu_kanban", "text" => "summary"},
       self(), "ou_admin"}
    )

    # Directive must hit the kanban FAA, NOT the dev FAA.
    assert_receive {:relay, :kanban,
                    {:outbound, %{"kind" => "reply", "args" => %{"text" => "summary"}}}},
                   500

    refute_receive {:relay, :dev, _}, 200

    assert_receive {:push_envelope,
                    %{
                      "req_id" => "req-x",
                      "ok" => true,
                      "data" => %{"cross_app" => true}
                    }},
                   500
  end

  test "cross-app reply forbidden when principal lacks target ws cap", ctx do
    # No ws_kanban cap.
    grant_caps("ou_admin", [])
    put_chat_in_workspace("ws_kanban", "oc_kanban", "feishu_kanban")

    {:ok, peer} =
      GenServer.start_link(
        FeishuChatProxy,
        fcp_args(%{
          session_id: "S_PRA4_FORBID",
          neighbors: [feishu_app_proxy: ctx.dev_pid]
        })
      )

    send(
      peer,
      {:tool_invoke, "req-forbid", "reply",
       %{"chat_id" => "oc_kanban", "app_id" => "feishu_kanban", "text" => "x"},
       self(), "ou_admin"}
    )

    assert_receive {:push_envelope,
                    %{
                      "req_id" => "req-forbid",
                      "ok" => false,
                      "error" => %{"type" => "forbidden", "workspace" => "ws_kanban"}
                    }},
                   500

    refute_receive {:relay, :kanban, _}, 200
    refute_receive {:relay, :dev, _}, 200
  end

  test "cross-app reply unknown_chat_in_app when workspace_for_chat misses", ctx do
    # Cap on a workspace that doesn't matter — the workspace lookup
    # for (chat_id, app_id) fails first because no row was seeded.
    grant_caps("ou_admin", ["workspace:ws_kanban/msg.send"])
    # Intentionally do NOT call put_chat_in_workspace — this is the
    # unknown_chat_in_app trigger (Workspaces.Registry returns :not_found).

    {:ok, peer} =
      GenServer.start_link(
        FeishuChatProxy,
        fcp_args(%{
          session_id: "S_PRA4_UCHAT",
          neighbors: [feishu_app_proxy: ctx.dev_pid]
        })
      )

    send(
      peer,
      {:tool_invoke, "req-uchat", "reply",
       %{"chat_id" => "oc_unmapped", "app_id" => "feishu_kanban", "text" => "x"},
       self(), "ou_admin"}
    )

    assert_receive {:push_envelope,
                    %{
                      "req_id" => "req-uchat",
                      "ok" => false,
                      "error" => %{
                        "type" => "unknown_chat_in_app",
                        "app_id" => "feishu_kanban",
                        "chat_id" => "oc_unmapped"
                      }
                    }},
                   500

    refute_receive {:relay, :kanban, _}, 200
    refute_receive {:relay, :dev, _}, 200
  end

  test "cross-app reply unknown_app when no FAA registered for target", ctx do
    grant_caps("ou_admin", ["workspace:ws_unknown/msg.send"])
    put_chat_in_workspace("ws_unknown", "oc_x", "feishu_unregistered")

    {:ok, peer} =
      GenServer.start_link(
        FeishuChatProxy,
        fcp_args(%{
          session_id: "S_PRA4_UNK",
          neighbors: [feishu_app_proxy: ctx.dev_pid]
        })
      )

    send(
      peer,
      {:tool_invoke, "req-unk", "reply",
       %{"chat_id" => "oc_x", "app_id" => "feishu_unregistered", "text" => "x"},
       self(), "ou_admin"}
    )

    assert_receive {:push_envelope,
                    %{
                      "req_id" => "req-unk",
                      "ok" => false,
                      "error" => %{
                        "type" => "unknown_app",
                        "app_id" => "feishu_unregistered"
                      }
                    }},
                   500
  end

  test "cross-app reply strips reply_to_message_id and edit_message_id", ctx do
    # NOTE: plan §Step 2 originally called Esr.Resource.Capability.put_principal_caps/2
    # and Esr.Resource.Workspace.Registry.put_chat_workspace/2, neither of which
    # exists. Replaced with the same helpers the other tests use.
    grant_caps("ou_admin", ["workspace:ws_kanban/msg.send"])
    put_chat_in_workspace("ws_kanban", "oc_kanban", "feishu_kanban")

    {:ok, peer} =
      GenServer.start_link(
        FeishuChatProxy,
        fcp_args(%{
          session_id: "S_PRA4_STRIP",
          neighbors: [feishu_app_proxy: ctx.dev_pid]
        })
      )

    # Lower primary log level so capture_log sees Logger.info — same
    # pattern as feishu_chat_proxy_test.exs:103-106.
    original_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: original_level) end)

    log =
      capture_log(fn ->
        send(
          peer,
          {:tool_invoke, "req-strip", "reply",
           %{
             "chat_id" => "oc_kanban",
             "app_id" => "feishu_kanban",
             "text" => "x",
             "reply_to_message_id" => "om_OLD",
             "edit_message_id" => "om_OLDER"
           }, self(), "ou_admin"}
        )

        # Drain the FCP mailbox + relay roundtrip. By the time the
        # relay forwards the outbound to us, the Logger.info call has
        # been issued; the small sleep covers async logger flush.
        assert_receive {:relay, :kanban,
                        {:outbound, %{"kind" => "reply", "args" => args}}},
                       500

        refute Map.has_key?(args, "reply_to_message_id")
        refute Map.has_key?(args, "edit_message_id")

        Process.sleep(50)
      end)

    # Beyond the args-shape assertion (which dispatch_to_target_app
    # satisfies trivially via literal envelope construction), prove
    # the cross-app strip *branch* fired by checking the info log.
    assert log =~ "FCP cross-app: stripping reply_to/edit ids"
    assert log =~ "om_OLD"
    assert log =~ "om_OLDER"
  end

  test "cross-app reply does NOT log the strip notice when ids absent", ctx do
    grant_caps("ou_admin", ["workspace:ws_kanban/msg.send"])
    put_chat_in_workspace("ws_kanban", "oc_kanban", "feishu_kanban")

    {:ok, peer} =
      GenServer.start_link(
        FeishuChatProxy,
        fcp_args(%{
          session_id: "S_PRA4_NOSTRIP",
          neighbors: [feishu_app_proxy: ctx.dev_pid]
        })
      )

    original_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: original_level) end)

    log =
      capture_log(fn ->
        send(
          peer,
          {:tool_invoke, "req-nostrip", "reply",
           %{"chat_id" => "oc_kanban", "app_id" => "feishu_kanban", "text" => "x"},
           self(), "ou_admin"}
        )

        assert_receive {:relay, :kanban, {:outbound, _}}, 500
        Process.sleep(50)
      end)

    refute log =~ "FCP cross-app: stripping reply_to/edit ids"
  end
end
