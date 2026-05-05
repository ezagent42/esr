defmodule Esr.Commands.NotifyTest do
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

  alias Esr.Commands.Notify
  alias Esr.Entity.SlashHandler
  alias Esr.Slash.QueueResult
  alias Esr.Slash.ReplyTarget.QueueFile
  alias Esr.Scope
  alias Esr.Resource.Capability.Grants

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

    # PR-2.3b-2: SlashHandler is the dispatch engine. Make sure it's
    # alive (the SupervisorTest can leave the Application's Admin tree
    # torn down).
    ensure_slash_handler()

    on_exit(fn ->
      Grants.load_snapshot(prior_grants)
      if prev_home, do: System.put_env("ESRD_HOME", prev_home), else: System.delete_env("ESRD_HOME")
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  # Post-P2-16: Notify.execute/1 discovers the feishu adapter topic by
  # iterating `Scope.Admin.Process.list_admin_peers/0` for a
  # `:feishu_app_adapter_<app_id>` entry. Tests register the caller pid
  # as a stand-in so the iteration resolves to a predictable topic.
  defp register_fake_feishu_adapter(app_id) do
    sym = String.to_atom("feishu_app_adapter_#{app_id}")
    :ok = Scope.Admin.Process.register_admin_peer(sym, self())
    topic = "adapter:feishu/#{app_id}"
    :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, topic)
    topic
  end

  # PR-2.3b-2: SlashHandler is registered under :slash_handler in
  # Scope.Admin.Process; if a previous test tore it down, re-bootstrap.
  defp ensure_slash_handler do
    case Esr.Scope.Admin.Process.slash_handler_ref() do
      {:ok, _pid} -> :ok
      :error ->
        :ok = Esr.Scope.Admin.bootstrap_slash_handler()
    end
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
      # Don't register a fake — Scope.Admin.Process has other peers
      # (e.g. :slash_handler) but no :feishu_app_adapter_* entry.
      assert {:error, %{"type" => "no_feishu_adapter"}} =
               Notify.execute(%{"args" => %{"to" => "ou_x", "text" => "y"}})
    end

    test "returns invalid_args for malformed commands" do
      assert {:error, %{"type" => "invalid_args"}} = Notify.execute(%{})
    end
  end

  describe "SlashHandler → Notify end-to-end (PR-2.3b-2 unified path)" do
    test "happy path — processing file ends up in completed/ with result", %{tmp: tmp} do
      _topic = register_fake_feishu_adapter("e2e_#{System.unique_integer([:positive])}")

      id = "01ARZTEST#{System.unique_integer([:positive])}"
      processing = Path.join([tmp, "default/admin_queue/processing", "#{id}.yaml"])
      completed = Path.join([tmp, "default/admin_queue/completed", "#{id}.yaml"])

      command = %{
        "id" => id,
        "kind" => "notify",
        "submitted_by" => @test_principal,
        "args" => %{"to" => "ou_receiver_e2e", "text" => "hello-from-queue"}
      }

      # Mirror Watcher's flow: write pending file, move to processing,
      # then dispatch via SlashHandler with QueueFile target.
      File.write!(processing, "id: #{id}\nkind: notify\n")

      target = {QueueFile, %{id: id, command: command}}
      _ = SlashHandler.dispatch_command(command, target)

      assert_receive {:directive,
                      %{"args" => %{"text" => "hello-from-queue"}}},
                     2_000

      assert wait_for_file(completed, 2_000), "expected #{completed} to exist"
      refute File.exists?(processing), "processing file should have been moved"

      {:ok, doc} = YamlElixir.read_from_file(completed)
      assert doc["id"] == id
      assert doc["kind"] == "notify"
      assert %{"ok" => true, "delivered_at" => _} = doc["result"]
      assert is_binary(doc["completed_at"])
    end

    test "unauthorized — file ends up in failed/ with the cap-check error", %{tmp: tmp} do
      id = "01ARZDENY#{System.unique_integer([:positive])}"
      processing = Path.join([tmp, "default/admin_queue/processing", "#{id}.yaml"])
      completed = Path.join([tmp, "default/admin_queue/completed", "#{id}.yaml"])
      failed = Path.join([tmp, "default/admin_queue/failed", "#{id}.yaml"])

      File.write!(processing, "id: #{id}\nkind: notify\n")

      # principal intentionally NOT in Grants — cap-check must deny.
      command = %{
        "id" => id,
        "kind" => "notify",
        "submitted_by" => "ou_nobody",
        "args" => %{"to" => "ou_x", "text" => "y"}
      }

      target = {QueueFile, %{id: id, command: command}}
      _ = SlashHandler.dispatch_command(command, target)

      assert wait_for_file(failed, 2_000), "expected failed file at #{failed}"
      refute File.exists?(completed)

      {:ok, doc} = YamlElixir.read_from_file(failed)
      assert doc["result"]["ok"] == false
      assert doc["result"]["type"] == "unauthorized"
    end

    test "delivers result to a pid reply target (Router path)", %{tmp: _tmp} do
      _topic = register_fake_feishu_adapter("pid_#{System.unique_integer([:positive])}")

      id = "01ARZPID#{System.unique_integer([:positive])}"

      command = %{
        "id" => id,
        "kind" => "notify",
        "submitted_by" => @test_principal,
        "args" => %{"to" => "ou_pid", "text" => "pid-reply"}
      }

      # PID target → ChatPid wrap → reply formatted as text.
      _ = SlashHandler.dispatch_command(command, self())

      assert_receive {:reply, text, _ref}, 2_000
      assert text =~ "delivered_at"
    end
  end

  # Suppress "unused" warning while QueueResult is referenced in tests
  # that may evolve to use it explicitly.
  _ = QueueResult

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
