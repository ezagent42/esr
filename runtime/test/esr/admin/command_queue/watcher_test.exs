defmodule Esr.Admin.CommandQueue.WatcherTest do
  @moduledoc """
  DI-7b Task 14d — Watcher boot-time orphan scan.

  These tests target `Watcher.init/1`'s two recovery sweeps:

    1. `scan_pending_orphans/1` — any `pending/*.yaml` already on disk
       when the Watcher boots is re-cast to `Esr.Admin.Dispatcher`.
       This covers the "esrd killed between pending-write and
       fs_watch arming" window.

    2. `scan_stale_processing/0` — any `processing/*.yaml` whose
       mtime is older than 10 min is renamed back to `pending/`.
       This covers "Dispatcher crashed mid-command" — the file would
       otherwise be stranded in `processing/` forever.

    Commands are idempotent per §9.3, so re-dispatch is safe.

  Setup mirrors the Janitor/Dispatcher tests: disposable ESRD_HOME,
  wildcard grant so the re-cast notify command actually runs end-to-end
  in test #1 (easier than mocking the Dispatcher GenServer). Test #2 is
  a pure file-move assertion and does not require a live Dispatcher.
  """

  use ExUnit.Case, async: false

  alias Esr.Admin.CommandQueue.Watcher
  alias Esr.Scope
  alias Esr.Capabilities.Grants

  @test_principal "ou_watcher_test"

  # Post-P2-16: register_fake_feishu_adapter/1 replaces the old
  # HubRegistry.bind dance for Notify routing.
  defp register_fake_feishu_adapter(app_id) do
    sym = String.to_atom("feishu_app_adapter_#{app_id}")
    :ok = Scope.Admin.Process.register_admin_peer(sym, self())
    topic = "adapter:feishu/#{app_id}"
    :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, topic)
    topic
  end

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "admin_watcher_#{System.unique_integer([:positive])}"
      )

    pending = Path.join(tmp, "default/admin_queue/pending")
    processing = Path.join(tmp, "default/admin_queue/processing")
    completed = Path.join(tmp, "default/admin_queue/completed")
    failed = Path.join(tmp, "default/admin_queue/failed")

    File.mkdir_p!(pending)
    File.mkdir_p!(processing)
    File.mkdir_p!(completed)
    File.mkdir_p!(failed)

    prev_home = System.get_env("ESRD_HOME")
    System.put_env("ESRD_HOME", tmp)

    prior_grants = snapshot_grants()
    Grants.load_snapshot(Map.put(prior_grants, @test_principal, ["*"]))

    # Ensure the full Admin supervision tree is alive (Dispatcher is
    # required for the orphan-resubmit test to complete end-to-end).
    ensure_admin_supervisor()

    # Stop the application-started Watcher so our test can own the
    # singleton and its init/1 observes the seeded tmp dirs. Note:
    # because Admin.Supervisor is `:rest_for_one`, terminating the
    # Dispatcher would also kill the Watcher — but NOT vice-versa, so
    # stopping just the Watcher here preserves the Dispatcher.
    stop_admin_watcher()

    on_exit(fn ->
      Grants.load_snapshot(prior_grants)

      if prev_home,
        do: System.put_env("ESRD_HOME", prev_home),
        else: System.delete_env("ESRD_HOME")

      File.rm_rf!(tmp)

      # Best-effort: let Esr.Admin.Supervisor restart the Watcher for
      # subsequent test modules. Resilient to the supervisor itself
      # having been torn down by another test.
      restart_admin_children()
    end)

    {:ok, tmp: tmp, pending: pending, processing: processing, completed: completed}
  end

  test "on init, resubmits pending/*.yaml orphans to the Dispatcher",
       %{tmp: tmp, pending: pending, completed: completed} do
    _topic = register_fake_feishu_adapter("watcher_pending_#{System.unique_integer([:positive])}")

    id = "01ARZWATCH#{System.unique_integer([:positive])}"
    orphan = Path.join(pending, "#{id}.yaml")
    completed_path = Path.join(completed, "#{id}.yaml")

    # Write a valid notify command to pending/ *before* starting the
    # Watcher. Its init/1 sweep should discover and re-cast it.
    yaml = """
    id: #{id}
    kind: notify
    submitted_by: #{@test_principal}
    args:
      to: ou_receiver
      text: resubmitted
    """

    File.write!(orphan, yaml)

    {:ok, _pid} = Watcher.start_link([])

    # The re-cast is handled by the real Dispatcher — it writes the
    # completed/<id>.yaml just like Task 14's happy path.
    assert wait_for_file(completed_path, 2_000),
           "expected completed/#{id}.yaml at #{completed_path} — tmp=#{tmp}"
  end

  test "on init, moves stale processing/*.yaml (>10min) back to pending/",
       %{pending: pending, processing: processing} do
    # This test targets the pure rename step in scan_stale_processing/2.
    # We disable the real Dispatcher for this test so the subsequent
    # pending-orphan sweep cannot advance the file past pending/, and
    # the post-move state we assert is stable.
    stop_admin_dispatcher()

    id = "01ARZSTALE#{System.unique_integer([:positive])}"
    stale = Path.join(processing, "#{id}.yaml")
    recovered = Path.join(pending, "#{id}.yaml")

    # Give it a shape the Dispatcher would reject quickly if it were
    # up, just to be extra safe: no `kind` key.
    File.write!(stale, "id: #{id}\n")
    # mtime 11 minutes in the past — well past the 10-min cutoff.
    File.touch!(stale, System.system_time(:second) - 11 * 60)

    {:ok, _pid} = Watcher.start_link([])

    # init/1 runs synchronously before start_link returns, so the
    # rename has already happened by this point. With the Dispatcher
    # down, the pending-orphan sweep's cast is a no-op (no registered
    # name) and the file stays put in pending/.
    refute File.exists?(stale)
    assert File.exists?(recovered)
  end

  test "on init, leaves fresh processing/*.yaml (<10min) alone",
       %{processing: processing} do
    stop_admin_dispatcher()

    id = "01ARZFRESH#{System.unique_integer([:positive])}"
    fresh = Path.join(processing, "#{id}.yaml")

    File.write!(fresh, "id: #{id}\n")
    # 30s old — well under the 10-min cutoff.
    File.touch!(fresh, System.system_time(:second) - 30)

    {:ok, _pid} = Watcher.start_link([])

    assert File.exists?(fresh),
           "fresh processing file should not have been moved back to pending"
  end

  # ------------------------------------------------------------------
  # helpers
  # ------------------------------------------------------------------

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
      :ok, _acc ->
        {:halt, true}

      :wait, _acc ->
        if System.monotonic_time(:millisecond) > deadline,
          do: {:halt, false},
          else: {:cont, :wait}
    end)
  end

  defp ensure_admin_supervisor do
    if Process.whereis(Esr.Admin.Supervisor) == nil do
      case Supervisor.restart_child(Esr.Supervisor, Esr.Admin.Supervisor) do
        {:ok, _} ->
          :ok

        {:ok, _, _} ->
          :ok

        _ ->
          # Last resort — stand one up directly.
          {:ok, _} = Esr.Admin.Supervisor.start_link([])
          :ok
      end
    else
      :ok
    end
  end

  defp stop_admin_watcher do
    case Process.whereis(Esr.Admin.CommandQueue.Watcher) do
      nil ->
        :ok

      _pid ->
        if Process.whereis(Esr.Admin.Supervisor) do
          _ =
            Supervisor.terminate_child(
              Esr.Admin.Supervisor,
              Esr.Admin.CommandQueue.Watcher
            )
        end

        :ok
    end
  end

  defp stop_admin_dispatcher do
    case Process.whereis(Esr.Admin.Dispatcher) do
      nil ->
        :ok

      _pid ->
        if Process.whereis(Esr.Admin.Supervisor) do
          # :rest_for_one means terminating Dispatcher also stops the
          # Watcher and Janitor — our `stop_admin_watcher/0` call in
          # `setup` already handled Watcher; Janitor is harmless here.
          _ =
            Supervisor.terminate_child(
              Esr.Admin.Supervisor,
              Esr.Admin.Dispatcher
            )
        end

        :ok
    end
  end

  defp restart_admin_children do
    if Process.whereis(Esr.Admin.Supervisor) do
      # Dispatcher first — :rest_for_one means restarting it
      # re-establishes the tail (Watcher + Janitor) automatically.
      _ = Supervisor.restart_child(Esr.Admin.Supervisor, Esr.Admin.Dispatcher)
      _ = Supervisor.restart_child(Esr.Admin.Supervisor, Esr.Admin.CommandQueue.Watcher)
    end

    :ok
  end

  defp snapshot_grants do
    :ets.tab2list(:esr_capabilities_grants) |> Map.new()
  rescue
    _ -> %{}
  end
end
