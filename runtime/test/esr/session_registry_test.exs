defmodule Esr.SessionRegistryTest do
  use ExUnit.Case, async: false

  setup do
    # Esr.SessionRegistry is started by the application supervisor
    # (see Esr.Application). Tests share this singleton.
    assert is_pid(Process.whereis(Esr.SessionRegistry))
    :ok
  end

  test "loads agents.yaml and exposes agent_def/1" do
    path = Path.expand("fixtures/agents/simple.yaml", __DIR__)
    :ok = Esr.SessionRegistry.load_agents(path)

    assert {:ok, agent_def} = Esr.SessionRegistry.agent_def("cc")
    assert agent_def.description == "Claude Code"
    assert "session:default/create" in agent_def.capabilities_required
    # P3-6: `simple.yaml` now ships the full CC chain (inbound length 4).
    assert length(agent_def.pipeline.inbound) == 4
  end

  test "returns error for unknown agent" do
    assert {:error, :not_found} = Esr.SessionRegistry.agent_def("nonexistent")
  end

  test "registers session and looks up by chat_thread" do
    :ok =
      Esr.SessionRegistry.register_session(
        "session-1",
        %{chat_id: "c1", app_id: "a1", thread_id: "t1"},
        %{}
      )

    assert {:ok, "session-1", _peer_refs} =
             Esr.SessionRegistry.lookup_by_chat_thread("c1", "a1", "t1")
  end

  test "lookup_by_chat_thread/3 does not call into the SessionRegistry GenServer" do
    sid = "no-gs-call-#{System.unique_integer([:positive])}"

    chat = %{
      chat_id: "oc_#{System.unique_integer([:positive])}",
      app_id: "app_#{System.unique_integer([:positive])}",
      thread_id: "om_#{System.unique_integer([:positive])}"
    }

    :ok =
      Esr.SessionRegistry.register_session(sid, chat, %{feishu_chat_proxy: self()})

    # Snapshot the registry's message-queue length before the lookup.
    # If the lookup is a direct ETS read, it never touches this mailbox.
    {:message_queue_len, before} =
      Process.info(Process.whereis(Esr.SessionRegistry), :message_queue_len)

    assert {:ok, ^sid, _refs} =
             Esr.SessionRegistry.lookup_by_chat_thread(chat.chat_id, chat.app_id, chat.thread_id)

    {:message_queue_len, after_lookup} =
      Process.info(Process.whereis(Esr.SessionRegistry), :message_queue_len)

    assert after_lookup <= before,
           "lookup_by_chat_thread should not enqueue any message on the SessionRegistry mailbox"

    Esr.SessionRegistry.unregister_session(sid)
  end

  test "SessionRegistry has no handle_call clause for :lookup_by_chat_thread after P6-A1" do
    # Authoritative source-grep gate. Post-A1 the function is a direct
    # ETS read — no `handle_call({:lookup_by_chat_thread, ...}, ...)`
    # clause must exist.
    src = File.read!("lib/esr/session_registry.ex")

    refute src =~ ~r/handle_call\(\s*\{:lookup_by_chat_thread/,
           "lookup_by_chat_thread must be a direct ETS read, not a handle_call"
  end

  test "unregister_session removes the ETS entry so subsequent lookup returns :not_found" do
    sid = "unreg-#{System.unique_integer([:positive])}"

    chat = %{
      chat_id: "oc_unreg_#{System.unique_integer([:positive])}",
      app_id: "app_unreg_#{System.unique_integer([:positive])}",
      thread_id: "om_unreg_#{System.unique_integer([:positive])}"
    }

    :ok = Esr.SessionRegistry.register_session(sid, chat, %{feishu_chat_proxy: self()})

    assert {:ok, ^sid, _} =
             Esr.SessionRegistry.lookup_by_chat_thread(chat.chat_id, chat.app_id, chat.thread_id)

    :ok = Esr.SessionRegistry.unregister_session(sid)

    assert :not_found =
             Esr.SessionRegistry.lookup_by_chat_thread(chat.chat_id, chat.app_id, chat.thread_id)
  end

  test "re-registering a session overwrites refs in the ETS index" do
    sid = "rereg-#{System.unique_integer([:positive])}"

    chat = %{
      chat_id: "oc_rereg_#{System.unique_integer([:positive])}",
      app_id: "app_rereg_#{System.unique_integer([:positive])}",
      thread_id: "om_rereg_#{System.unique_integer([:positive])}"
    }

    pid1 = spawn(fn -> :timer.sleep(:infinity) end)
    pid2 = spawn(fn -> :timer.sleep(:infinity) end)

    :ok = Esr.SessionRegistry.register_session(sid, chat, %{feishu_chat_proxy: pid1})

    assert {:ok, ^sid, %{feishu_chat_proxy: ^pid1}} =
             Esr.SessionRegistry.lookup_by_chat_thread(chat.chat_id, chat.app_id, chat.thread_id)

    :ok = Esr.SessionRegistry.register_session(sid, chat, %{feishu_chat_proxy: pid2})

    assert {:ok, ^sid, %{feishu_chat_proxy: ^pid2}} =
             Esr.SessionRegistry.lookup_by_chat_thread(chat.chat_id, chat.app_id, chat.thread_id)

    Esr.SessionRegistry.unregister_session(sid)
    Process.exit(pid1, :kill)
    Process.exit(pid2, :kill)
  end

  describe "PR-A multi-app: 3-tuple key" do
    test "register + lookup uses (chat_id, app_id, thread_id)" do
      sid = "S_PRA1"

      :ok =
        Esr.SessionRegistry.register_session(
          sid,
          %{chat_id: "oc_X", app_id: "feishu_dev", thread_id: ""},
          %{}
        )

      assert {:ok, ^sid, %{}} =
               Esr.SessionRegistry.lookup_by_chat_thread("oc_X", "feishu_dev", "")

      assert :not_found =
               Esr.SessionRegistry.lookup_by_chat_thread("oc_X", "feishu_kanban", "")

      Esr.SessionRegistry.unregister_session(sid)
    end

    test "two apps over the same chat_id keep distinct sessions" do
      :ok =
        Esr.SessionRegistry.register_session(
          "S_DEV",
          %{chat_id: "oc_shared", app_id: "feishu_dev", thread_id: ""},
          %{}
        )

      :ok =
        Esr.SessionRegistry.register_session(
          "S_KANBAN",
          %{chat_id: "oc_shared", app_id: "feishu_kanban", thread_id: ""},
          %{}
        )

      assert {:ok, "S_DEV", _} =
               Esr.SessionRegistry.lookup_by_chat_thread("oc_shared", "feishu_dev", "")

      assert {:ok, "S_KANBAN", _} =
               Esr.SessionRegistry.lookup_by_chat_thread("oc_shared", "feishu_kanban", "")

      Esr.SessionRegistry.unregister_session("S_DEV")
      Esr.SessionRegistry.unregister_session("S_KANBAN")
    end
  end

  test "reserved field names in agents.yaml trigger WARN log" do
    path = Path.join(System.tmp_dir!(), "reserved_test.yaml")
    File.write!(path, ~S"""
    agents:
      demo:
        description: "demo"
        capabilities_required: []
        pipeline: {inbound: [], outbound: []}
        proxies: []
        params: []
        rate_limits: {}  # reserved
    """)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        :ok = Esr.SessionRegistry.load_agents(path)
      end)

    assert log =~ "reserved field"
    File.rm!(path)
  end

  describe "claim_uri/2 (PR-21g D8 uniqueness)" do
    setup do
      # Distinct prefix per test so concurrent tests don't see each other's
      # rows under the singleton ETS table.
      env = "test-env-#{System.unique_integer([:positive])}"
      {:ok, env: env}
    end

    test "first claim succeeds; second claim with same name rejects", %{env: env} do
      sid_a = "sid-a-#{System.unique_integer([:positive])}"
      sid_b = "sid-b-#{System.unique_integer([:positive])}"

      assert :ok =
               Esr.SessionRegistry.claim_uri(sid_a, %{
                 env: env,
                 username: "linyilun",
                 workspace: "esr-dev",
                 name: "feature-foo",
                 worktree_branch: "feature-foo"
               })

      assert {:error, {:name_taken, ^sid_a}} =
               Esr.SessionRegistry.claim_uri(sid_b, %{
                 env: env,
                 username: "linyilun",
                 workspace: "esr-dev",
                 name: "feature-foo",
                 # Different worktree branch — name collision wins
                 worktree_branch: "feature-bar"
               })

      :ok = Esr.SessionRegistry.unregister_session(sid_a)
    end

    test "claim with same worktree_branch but different name rejects", %{env: env} do
      sid_a = "sid-wt-a-#{System.unique_integer([:positive])}"
      sid_b = "sid-wt-b-#{System.unique_integer([:positive])}"

      :ok =
        Esr.SessionRegistry.claim_uri(sid_a, %{
          env: env,
          username: "linyilun",
          workspace: "esr-dev",
          name: "session-one",
          worktree_branch: "shared-branch"
        })

      assert {:error, {:worktree_taken, ^sid_a}} =
               Esr.SessionRegistry.claim_uri(sid_b, %{
                 env: env,
                 username: "linyilun",
                 workspace: "esr-dev",
                 name: "session-two",
                 worktree_branch: "shared-branch"
               })

      :ok = Esr.SessionRegistry.unregister_session(sid_a)
    end

    test "different (env, username, workspace) tuples don't collide", %{env: env} do
      sid_a = "sid-iso-a-#{System.unique_integer([:positive])}"
      sid_b = "sid-iso-b-#{System.unique_integer([:positive])}"
      sid_c = "sid-iso-c-#{System.unique_integer([:positive])}"

      base = %{
        env: env,
        username: "linyilun",
        workspace: "esr-dev",
        name: "same-name",
        worktree_branch: "same-branch"
      }

      assert :ok = Esr.SessionRegistry.claim_uri(sid_a, base)
      # Different username → no collision
      assert :ok = Esr.SessionRegistry.claim_uri(sid_b, %{base | username: "yaoshengyue"})
      # Different workspace → no collision
      assert :ok = Esr.SessionRegistry.claim_uri(sid_c, %{base | workspace: "voice-gateway"})

      for sid <- [sid_a, sid_b, sid_c] do
        :ok = Esr.SessionRegistry.unregister_session(sid)
      end
    end

    test "lookup_by_name/4 returns sid; unregister clears the index", %{env: env} do
      sid = "sid-lookup-#{System.unique_integer([:positive])}"

      :ok =
        Esr.SessionRegistry.claim_uri(sid, %{
          env: env,
          username: "linyilun",
          workspace: "esr-dev",
          name: "feature-foo",
          worktree_branch: "feature-foo"
        })

      assert {:ok, ^sid} =
               Esr.SessionRegistry.lookup_by_name(env, "linyilun", "esr-dev", "feature-foo")

      :ok = Esr.SessionRegistry.unregister_session(sid)
      assert :not_found =
               Esr.SessionRegistry.lookup_by_name(env, "linyilun", "esr-dev", "feature-foo")
    end

    test "list_uris/3 enumerates only the requested prefix", %{env: env} do
      sid_a = "sid-list-a-#{System.unique_integer([:positive])}"
      sid_b = "sid-list-b-#{System.unique_integer([:positive])}"

      :ok =
        Esr.SessionRegistry.claim_uri(sid_a, %{
          env: env,
          username: "linyilun",
          workspace: "esr-dev",
          name: "alpha",
          worktree_branch: "alpha-br"
        })

      :ok =
        Esr.SessionRegistry.claim_uri(sid_b, %{
          env: env,
          username: "linyilun",
          workspace: "esr-dev",
          name: "beta",
          worktree_branch: "beta-br"
        })

      names =
        Esr.SessionRegistry.list_uris(env, "linyilun", "esr-dev")
        |> Enum.map(fn {n, _} -> n end)
        |> Enum.sort()

      assert names == ["alpha", "beta"]

      for sid <- [sid_a, sid_b] do
        :ok = Esr.SessionRegistry.unregister_session(sid)
      end
    end
  end
end
