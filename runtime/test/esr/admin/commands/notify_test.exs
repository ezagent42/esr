defmodule Esr.Admin.Commands.NotifyTest do
  @moduledoc """
  DI-7 Task 14 — end-to-end exercise of the admin queue pipeline with
  `Commands.Notify` as the first real command.

  Verification strategy — **direct-cast, not fs_watch.** Writing a
  YAML file into `admin_queue/pending/` and waiting for the Watcher's
  FileSystem subscription to fire is flaky on macOS FSEvents (the
  coalescing window can drop fast-fire test events entirely). The
  Watcher → Dispatcher edge is covered by the dedicated Watcher test
  in DI-5; this test exercises the *Dispatcher execution flow* by
  casting directly with `{:reply_to, {:file, path}}`, which is the
  same message the Watcher would have produced. The on-disk side
  (pending → processing → completed move) is still fully exercised —
  the test pre-stages a file in `pending/` so the Dispatcher has
  something to rename.
  """

  use ExUnit.Case, async: false

  alias Esr.Admin.Commands.Notify
  alias Esr.Admin.Dispatcher
  alias Esr.AdminSessionProcess
  alias Esr.Capabilities.Grants

  @test_principal "ou_notify_test"

  setup do
    tmp = Path.join(System.tmp_dir!(), "admin_notify_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "default/admin_queue/pending"))
    File.mkdir_p!(Path.join(tmp, "default/admin_queue/processing"))
    File.mkdir_p!(Path.join(tmp, "default/admin_queue/completed"))
    File.mkdir_p!(Path.join(tmp, "default/admin_queue/failed"))

    prev_home = System.get_env("ESRD_HOME")
    System.put_env("ESRD_HOME", tmp)

    # Wildcard grant for the test principal so the cap-check path lets
    # notify through. Grants.has? only matches bare "notify.send" via
    # the "*" literal (non-prefixed strings don't split on "/" — see
    # capabilities/grants.ex matches?/2).
    prior_grants = snapshot_grants()
    Grants.load_snapshot(Map.put(prior_grants, @test_principal, ["*"]))

    # Esr.Admin.SupervisorTest can leave the app-level Admin.Supervisor
    # in a terminated state (it calls Supervisor.terminate_child on it
    # and then starts a test-local replacement that dies with the test
    # process). When this test suite runs next, Esr.Admin.Dispatcher may
    # no longer be registered. Restart the app-level child so the named
    # process exists before we cast into it.
    ensure_admin_dispatcher()

    on_exit(fn ->
      Grants.load_snapshot(prior_grants)
      if prev_home, do: System.put_env("ESRD_HOME", prev_home), else: System.delete_env("ESRD_HOME")
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  # Post-P2-16: Notify.execute/1 discovers the feishu adapter topic by
  # iterating `AdminSessionProcess.list_admin_peers/0` for a
  # `:feishu_app_adapter_<app_id>` entry. Tests register the caller pid
  # as a stand-in so the iteration resolves to a predictable topic.
  defp register_fake_feishu_adapter(app_id) do
    sym = String.to_atom("feishu_app_adapter_#{app_id}")
    :ok = AdminSessionProcess.register_admin_peer(sym, self())
    topic = "adapter:feishu/#{app_id}"
    :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, topic)
    topic
  end

  # If the app-level Admin.Supervisor was torn down (by the supervisor
  # test) or never started, restart it so Esr.Admin.Dispatcher is alive
  # and registered under its named pid before any test casts into it.
  defp ensure_admin_dispatcher do
    if Process.whereis(Esr.Admin.Dispatcher) == nil do
      _ = Supervisor.restart_child(Esr.Supervisor, Esr.Admin.Supervisor)
      # Restart may return {:error, :running} if another test just
      # revived it, or {:error, :not_found} if it was never a child
      # (shouldn't happen — Application always lists it). Fall back to
      # start_supervised!-style direct start in either odd case.
      if Process.whereis(Esr.Admin.Dispatcher) == nil do
        {:ok, _} = Esr.Admin.Supervisor.start_link([])
      end
    end

    :ok
  end

  describe "Notify.execute/1 unit" do
    test "broadcasts a reply directive on the feishu adapter topic" do
      _topic = register_fake_feishu_adapter("test_app_#{System.unique_integer([:positive])}")

      assert {:ok, %{"delivered_at" => ts}} =
               Notify.execute(%{"args" => %{"to" => "ou_receiver", "text" => "hello"}})

      assert is_binary(ts)

      assert_receive {:directive,
                      %{
                        "kind" => "reply",
                        "args" => %{
                          "receive_id" => "ou_receiver",
                          "receive_id_type" => "open_id",
                          "text" => "hello"
                        }
                      }},
                     500
    end

    test "returns no_feishu_adapter when no feishu app adapter is registered" do
      # Don't register a fake — AdminSessionProcess has other peers
      # (e.g. :slash_handler) but no :feishu_app_adapter_* entry.
      assert {:error, %{"type" => "no_feishu_adapter"}} =
               Notify.execute(%{"args" => %{"to" => "ou_x", "text" => "y"}})
    end

    test "returns invalid_args for malformed commands" do
      assert {:error, %{"type" => "invalid_args"}} = Notify.execute(%{})
    end
  end

  describe "Dispatcher → Notify end-to-end (direct cast)" do
    test "happy path — pending file ends up in completed/ with result", %{tmp: tmp} do
      _topic = register_fake_feishu_adapter("e2e_#{System.unique_integer([:positive])}")

      id = "01ARZTEST#{System.unique_integer([:positive])}"
      pending = Path.join([tmp, "default/admin_queue/pending", "#{id}.yaml"])
      completed = Path.join([tmp, "default/admin_queue/completed", "#{id}.yaml"])

      File.write!(pending, """
      id: #{id}
      kind: notify
      submitted_by: #{@test_principal}
      args:
        to: ou_receiver_e2e
        text: hello-from-queue
      """)

      command = %{
        "id" => id,
        "kind" => "notify",
        "submitted_by" => @test_principal,
        "args" => %{"to" => "ou_receiver_e2e", "text" => "hello-from-queue"}
      }

      GenServer.cast(Dispatcher, {:execute, command, {:reply_to, {:file, completed}}})

      # Directive should arrive within a reasonable window (Task.start +
      # broadcast is effectively synchronous in the test process).
      assert_receive {:directive,
                      %{"args" => %{"text" => "hello-from-queue"}}},
                     2_000

      # The Dispatcher's handle_info may run slightly after the Task
      # broadcasts; give it a beat and poll for the completed file.
      assert wait_for_file(completed, 2_000), "expected #{completed} to exist"
      refute File.exists?(pending), "pending file should have been renamed away"

      refute File.exists?(
               Path.join([tmp, "default/admin_queue/processing", "#{id}.yaml"])
             ),
             "processing file should have been cleared"

      {:ok, doc} = YamlElixir.read_from_file(completed)
      assert doc["id"] == id
      assert doc["kind"] == "notify"
      assert %{"ok" => true, "delivered_at" => _} = doc["result"]
      assert is_binary(doc["completed_at"])
    end

    test "unauthorized — file ends up in failed/ with the cap-check error", %{tmp: tmp} do
      id = "01ARZDENY#{System.unique_integer([:positive])}"
      pending = Path.join([tmp, "default/admin_queue/pending", "#{id}.yaml"])
      completed = Path.join([tmp, "default/admin_queue/completed", "#{id}.yaml"])
      failed = Path.join([tmp, "default/admin_queue/failed", "#{id}.yaml"])

      File.write!(pending, "id: #{id}\nkind: notify\n")

      # principal intentionally NOT in Grants — cap-check must deny.
      command = %{
        "id" => id,
        "kind" => "notify",
        "submitted_by" => "ou_nobody",
        "args" => %{"to" => "ou_x", "text" => "y"}
      }

      GenServer.cast(Dispatcher, {:execute, command, {:reply_to, {:file, completed}}})

      assert wait_for_file(failed, 2_000), "expected failed file at #{failed}"
      refute File.exists?(pending)
      refute File.exists?(completed)

      {:ok, doc} = YamlElixir.read_from_file(failed)
      assert doc["result"]["ok"] == false
      assert doc["result"]["type"] == "unauthorized"
    end

    test "delivers result to a pid reply target (Router path)", %{tmp: _tmp} do
      _topic = register_fake_feishu_adapter("pid_#{System.unique_integer([:positive])}")

      id = "01ARZPID#{System.unique_integer([:positive])}"
      ref = make_ref()

      command = %{
        "id" => id,
        "kind" => "notify",
        "submitted_by" => @test_principal,
        "args" => %{"to" => "ou_pid", "text" => "pid-reply"}
      }

      GenServer.cast(Dispatcher, {:execute, command, {:reply_to, {:pid, self(), ref}}})

      assert_receive {:command_result, ^ref, {:ok, %{"delivered_at" => _}}}, 2_000
    end
  end

  # ------------------------------------------------------------------
  # helpers
  # ------------------------------------------------------------------

  # Dispatcher result move runs after the Task's send lands — poll so
  # the test doesn't race against the GenServer scheduler.
  defp wait_for_file(path, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      if File.exists?(path) do
        :ok
      else
        Process.sleep(25)
        :wait
      end
    end)
    |> Enum.reduce_while(:wait, fn
      :ok, _acc -> {:halt, true}
      :wait, _acc ->
        if System.monotonic_time(:millisecond) > deadline, do: {:halt, false}, else: {:cont, :wait}
    end)
  end

  # Build a map from the Grants ETS so we can restore prior state after
  # the test (Grants is a shared singleton — don't drop anyone else's
  # snapshot).
  defp snapshot_grants do
    :ets.tab2list(:esr_capabilities_grants) |> Map.new()
  rescue
    _ -> %{}
  end
end
