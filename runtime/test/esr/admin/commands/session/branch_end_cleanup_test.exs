defmodule Esr.Admin.Commands.Session.BranchEndCleanupTest do
  @moduledoc """
  DI-11 Task 25 — `Esr.Admin.Commands.Session.BranchEnd` (formerly
  `Session.End` before PR-3 P3-9 rename) non-force path: cleanup-check
  handshake via `session.signal_cleanup` MCP tool, with a 30-s soft
  timeout fallback.

  The handshake has three pieces:

    1. `Session.BranchEnd.execute/2` calls
       `Esr.Admin.Dispatcher.register_cleanup/2` to advertise its pid
       under `session_id = "<submitter>-<branch>"`.
    2. Its injected `:sender_fn` kicks off the cleanup-check (stubbed
       in these tests — there's no CC-side `cleanup_check` tool
       today; see `Session.BranchEnd` module doc).
    3. It blocks on `receive {:cleanup_signal, status, details}` with
       a `:cleanup_timeout_ms` override so the timeout branch can be
       exercised in < 1 s.

    4. In parallel, the test `Task.start`s a poker that sends
       `{:cleanup_signal, session_id, status, details}` to
       `Esr.Admin.Dispatcher`, which is the exact message shape the
       `session.signal_cleanup` MCP tool (Task 24) produces. The
       Dispatcher's new `handle_info/2` clause forwards it to the
       registered Session.BranchEnd Task.

  ## What is NOT tested here

  * The end-to-end pipe from CC's MCP tool_invoke to the Dispatcher —
    that's covered by `Esr.PeerServerSessionCleanupTest` (Task 24).
  * The `--force` happy paths (branches.yaml prune, routing.yaml
    prune, active fallback) — covered by
    `Esr.Admin.Commands.Session.BranchEndTest`.

  Both ends (Dispatcher routing + Session.BranchEnd blocking receive)
  are exercised together here, so the cleanup flow is covered
  end-to-end on the ESR side.
  """

  use ExUnit.Case, async: false

  alias Esr.Admin.Commands.Session.BranchEnd, as: SessionBranchEnd
  alias Esr.Admin.Dispatcher

  setup do
    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "admin_sessend_cleanup_#{unique}")
    File.mkdir_p!(Path.join(tmp, "default"))

    prev_home = System.get_env("ESRD_HOME")
    System.put_env("ESRD_HOME", tmp)

    ensure_dispatcher()

    on_exit(fn ->
      if prev_home,
        do: System.put_env("ESRD_HOME", prev_home),
        else: System.delete_env("ESRD_HOME")

      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  defp ensure_dispatcher do
    if Process.whereis(Esr.Admin.Dispatcher) == nil do
      _ = Supervisor.restart_child(Esr.Supervisor, Esr.Admin.Supervisor)

      if Process.whereis(Esr.Admin.Dispatcher) == nil do
        {:ok, _} = Esr.Admin.Supervisor.start_link([])
      end
    end

    :ok
  end

  defp write_single_branch_yaml(tmp, branch) do
    branches_path = Path.join([tmp, "default", "branches.yaml"])
    routing_path = Path.join([tmp, "default", "routing.yaml"])

    File.write!(branches_path, """
    branches:
      #{branch}:
        esrd_home: /tmp/esrd-#{branch}
        worktree_path: /tmp/worktree-#{branch}
        port: 54399
        status: running
    """)

    File.write!(routing_path, """
    principals:
      ou_alice:
        active: #{branch}
        targets:
          #{branch}:
            esrd_url: ws://127.0.0.1:54399/adapter_hub/socket/websocket?vsn=2.0.0
            cc_session_id: ou_alice-#{branch}
    """)

    {branches_path, routing_path}
  end

  # Spawns a poker that waits `delay_ms` then sends the cleanup signal
  # to the Dispatcher — mimicking what the `session.signal_cleanup`
  # MCP tool would do if CC invoked it.
  defp poke_signal_after(session_id, status, details, delay_ms \\ 20) do
    Task.start(fn ->
      Process.sleep(delay_ms)
      send(Dispatcher, {:cleanup_signal, session_id, status, details})
    end)
  end

  describe "non-force CLEANED path" do
    test "proceeds with esr-branch.sh end (no --force) and prunes yaml", %{tmp: tmp} do
      {branches_path, routing_path} = write_single_branch_yaml(tmp, "feature-foo")

      parent = self()

      cmd = %{
        "submitted_by" => "ou_alice",
        "args" => %{"branch" => "feature-foo"}
      }

      stub_spawn = fn {args} ->
        send(parent, {:spawned, args})
        {~s({"ok":true,"branch":"feature-foo"}\n), 0}
      end

      sender_fn = fn session_id, worktree_path ->
        send(parent, {:sender_called, session_id, worktree_path})
        # Simulate CC replying CLEANED ~20 ms later.
        poke_signal_after(session_id, "CLEANED", %{"files_removed" => 3})
        :ok
      end

      assert {:ok, %{"branch" => "feature-foo"}} =
               SessionBranchEnd.execute(cmd,
                 spawn_fn: stub_spawn,
                 sender_fn: sender_fn,
                 cleanup_timeout_ms: 500
               )

      # The handshake sender was invoked with the canonical session_id
      # + the worktree_path from branches.yaml.
      assert_received {:sender_called, "ou_alice-feature-foo", "/tmp/worktree-feature-foo"}

      # The shell was called WITHOUT --force — the signal was CLEANED.
      assert_received {:spawned, args}
      assert "end" in args
      assert "feature-foo" in args
      refute "--force" in args

      # Yaml was pruned just like the force path.
      {:ok, branches} = YamlElixir.read_from_file(branches_path)
      refute Map.has_key?(branches["branches"] || %{}, "feature-foo")

      {:ok, routing} = YamlElixir.read_from_file(routing_path)
      alice_targets = routing["principals"]["ou_alice"]["targets"] || %{}
      refute Map.has_key?(alice_targets, "feature-foo")
    end
  end

  describe "non-force blocking paths" do
    test "DIRTY signal returns worktree_dirty error; no shell call", %{tmp: tmp} do
      {_branches_path, _routing_path} = write_single_branch_yaml(tmp, "feature-bar")

      cmd = %{
        "submitted_by" => "ou_alice",
        "args" => %{"branch" => "feature-bar"}
      }

      spawn_guard = fn {_args} ->
        flunk("spawn must not be called when status=DIRTY")
      end

      sender_fn = fn session_id, _wpath ->
        poke_signal_after(session_id, "DIRTY", %{
          "modified" => ["lib/foo.ex"],
          "staged" => []
        })

        :ok
      end

      assert {:error,
              %{
                "type" => "worktree_dirty",
                "details" => %{"modified" => ["lib/foo.ex"]} = details,
                "branch" => "feature-bar"
              }} =
               SessionBranchEnd.execute(cmd,
                 spawn_fn: spawn_guard,
                 sender_fn: sender_fn,
                 cleanup_timeout_ms: 500
               )

      # Sanity: details is the opaque CC payload, passed through.
      assert Map.get(details, "staged") == []
    end

    test "UNPUSHED signal returns worktree_unpushed error", %{tmp: tmp} do
      {_branches_path, _routing_path} = write_single_branch_yaml(tmp, "feature-baz")

      cmd = %{
        "submitted_by" => "ou_alice",
        "args" => %{"branch" => "feature-baz", "force" => false}
      }

      spawn_guard = fn {_args} ->
        flunk("spawn must not be called when status=UNPUSHED")
      end

      sender_fn = fn session_id, _wpath ->
        poke_signal_after(session_id, "UNPUSHED", %{
          "ahead" => 2,
          "commits" => ["deadbeef wip", "cafef00d refactor"]
        })

        :ok
      end

      assert {:error,
              %{
                "type" => "worktree_unpushed",
                "details" => %{"ahead" => 2} = details,
                "branch" => "feature-baz"
              }} =
               SessionBranchEnd.execute(cmd,
                 spawn_fn: spawn_guard,
                 sender_fn: sender_fn,
                 cleanup_timeout_ms: 500
               )

      assert length(details["commits"]) == 2
    end

    test "STASHED signal returns worktree_stashed error", %{tmp: tmp} do
      {_, _} = write_single_branch_yaml(tmp, "feature-qux")

      cmd = %{
        "submitted_by" => "ou_alice",
        "args" => %{"branch" => "feature-qux"}
      }

      spawn_guard = fn {_args} -> flunk("spawn must not be called") end

      sender_fn = fn session_id, _wpath ->
        poke_signal_after(session_id, "STASHED", %{"stash_count" => 1})
        :ok
      end

      assert {:error, %{"type" => "worktree_stashed", "branch" => "feature-qux"}} =
               SessionBranchEnd.execute(cmd,
                 spawn_fn: spawn_guard,
                 sender_fn: sender_fn,
                 cleanup_timeout_ms: 500
               )
    end
  end

  describe "timeout branch" do
    test "no signal within cleanup_timeout_ms returns cleanup_timeout", %{tmp: tmp} do
      {_, _} = write_single_branch_yaml(tmp, "feature-silent")

      cmd = %{
        "submitted_by" => "ou_alice",
        "args" => %{"branch" => "feature-silent"}
      }

      spawn_guard = fn {_args} -> flunk("spawn must not be called on timeout") end

      # sender_fn is a noop — nobody sends a :cleanup_signal, so the
      # `after` clause should fire.
      silent_sender = fn _sid, _wpath -> :ok end

      t0 = System.monotonic_time(:millisecond)

      assert {:error,
              %{
                "type" => "cleanup_timeout",
                "branch" => "feature-silent",
                "timeout_ms" => 80,
                "hint" => hint
              }} =
               SessionBranchEnd.execute(cmd,
                 spawn_fn: spawn_guard,
                 sender_fn: silent_sender,
                 cleanup_timeout_ms: 80
               )

      elapsed = System.monotonic_time(:millisecond) - t0
      assert elapsed >= 80
      # Should not have taken the default 30s.
      assert elapsed < 5_000
      assert is_binary(hint)
      assert hint =~ "--force"
    end

    test "timeout still deregisters the pending_cleanup entry", %{tmp: tmp} do
      {_, _} = write_single_branch_yaml(tmp, "feature-leak")

      cmd = %{
        "submitted_by" => "ou_alice",
        "args" => %{"branch" => "feature-leak"}
      }

      silent_sender = fn _sid, _wpath -> :ok end

      assert {:error, %{"type" => "cleanup_timeout"}} =
               SessionBranchEnd.execute(cmd,
                 spawn_fn: fn {_} -> flunk("unreachable") end,
                 sender_fn: silent_sender,
                 cleanup_timeout_ms: 50
               )

      # After timeout, a late signal for the same session_id should be
      # dropped as stray (no pending waiter). We can't peek into
      # Dispatcher state directly, but sending a second signal
      # immediately should not crash the dispatcher and should just
      # log a warning — assert the dispatcher is still alive.
      send(Dispatcher, {:cleanup_signal, "ou_alice-feature-leak", "CLEANED", %{}})
      # Give the handle_info a moment.
      Process.sleep(20)
      assert Process.alive?(Process.whereis(Dispatcher))
    end
  end

  describe "force bypass" do
    test "args.force=true skips the handshake entirely", %{tmp: tmp} do
      {_, _} = write_single_branch_yaml(tmp, "feature-forced")

      parent = self()

      cmd = %{
        "submitted_by" => "ou_alice",
        "args" => %{"branch" => "feature-forced", "force" => true}
      }

      stub_spawn = fn {args} ->
        send(parent, {:spawned, args})
        {~s({"ok":true,"branch":"feature-forced"}\n), 0}
      end

      # sender_fn MUST NOT be called on force path.
      sender_guard = fn _sid, _wpath ->
        flunk("sender_fn must not be called on force path")
      end

      assert {:ok, %{"branch" => "feature-forced"}} =
               SessionBranchEnd.execute(cmd,
                 spawn_fn: stub_spawn,
                 sender_fn: sender_guard,
                 cleanup_timeout_ms: 10_000
               )

      # Force path MUST pass --force to the script.
      assert_received {:spawned, args}
      assert "--force" in args
    end
  end

  describe "default sender_fn (PubSub broadcast)" do
    test "broadcasts cleanup_check_requested on cli:channel/<cc_session_id>", %{tmp: tmp} do
      {_, _} = write_single_branch_yaml(tmp, "feature-broadcast")

      # routing.yaml written above has cc_session_id=ou_alice-feature-broadcast.
      expected_topic = "cli:channel/ou_alice-feature-broadcast"
      :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, expected_topic)

      cmd = %{
        "submitted_by" => "ou_alice",
        "args" => %{"branch" => "feature-broadcast"}
      }

      spawn_guard = fn {_args} -> flunk("spawn must not be called on timeout") end

      # Omit :sender_fn so the default (PubSub broadcast) is exercised.
      # Short timeout — we only want to capture the broadcast, not the signal.
      t0 = System.monotonic_time(:millisecond)

      assert {:error, %{"type" => "cleanup_timeout"}} =
               SessionBranchEnd.execute(cmd,
                 spawn_fn: spawn_guard,
                 cleanup_timeout_ms: 120
               )

      elapsed = System.monotonic_time(:millisecond) - t0
      assert elapsed >= 120
      assert elapsed < 5_000

      # The default sender_fn fires BEFORE the receive block, so the
      # broadcast is already in our mailbox by the time the timeout
      # resolves. A tiny assert_received window is fine.
      assert_receive {:notification, notification}, 200

      assert notification["kind"] == "cleanup_check_requested"
      assert notification["session_id"] == "ou_alice-feature-broadcast"
      assert notification["branch"] == "feature-broadcast"
      assert notification["worktree_path"] == "/tmp/worktree-feature-broadcast"
      assert is_binary(notification["instructions"])
      assert notification["instructions"] =~ "session.signal_cleanup"
      assert notification["instructions"] =~ "CLEANED"
      assert notification["instructions"] =~ "DIRTY"

      :ok = Phoenix.PubSub.unsubscribe(EsrWeb.PubSub, expected_topic)
    end

    test "falls back to <submitter>-<branch> when routing.yaml lacks cc_session_id",
         %{tmp: tmp} do
      # branches.yaml with a registered branch, but routing.yaml written
      # WITHOUT a cc_session_id key — simulating either a hand-edited
      # routing.yaml or a pre-Task-23 routing record.
      branches_path = Path.join([tmp, "default", "branches.yaml"])
      routing_path = Path.join([tmp, "default", "routing.yaml"])

      File.write!(branches_path, """
      branches:
        feature-noroute:
          esrd_home: /tmp/esrd-feature-noroute
          worktree_path: /tmp/worktree-feature-noroute
          port: 54400
          status: running
      """)

      File.write!(routing_path, """
      principals:
        ou_alice:
          active: feature-noroute
          targets:
            feature-noroute:
              esrd_url: ws://127.0.0.1:54400/adapter_hub/socket/websocket?vsn=2.0.0
      """)

      expected_topic = "cli:channel/ou_alice-feature-noroute"
      :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, expected_topic)

      cmd = %{
        "submitted_by" => "ou_alice",
        "args" => %{"branch" => "feature-noroute"}
      }

      assert {:error, %{"type" => "cleanup_timeout"}} =
               SessionBranchEnd.execute(cmd,
                 spawn_fn: fn {_} -> flunk("unreachable") end,
                 cleanup_timeout_ms: 80
               )

      assert_receive {:notification, notification}, 200
      assert notification["session_id"] == "ou_alice-feature-noroute"

      :ok = Phoenix.PubSub.unsubscribe(EsrWeb.PubSub, expected_topic)
    end
  end

  describe "dispatcher state tracking" do
    test "register_cleanup + deregister_cleanup round-trip is a no-op on the task side" do
      # Directly exercising the Dispatcher API to confirm the casts
      # neither crash nor hang when no signal arrives. This is a
      # regression guard for the state map surgery.
      :ok = Dispatcher.register_cleanup("ou_alice-regression", self())
      :ok = Dispatcher.deregister_cleanup("ou_alice-regression")

      # Dispatcher still healthy.
      assert Process.alive?(Process.whereis(Dispatcher))
    end

    test "cleanup_signal with no registered waiter is logged & dropped (not crash)" do
      send(Dispatcher, {:cleanup_signal, "ou_nobody-no-branch", "CLEANED", %{}})
      Process.sleep(20)
      assert Process.alive?(Process.whereis(Dispatcher))
    end
  end
end
