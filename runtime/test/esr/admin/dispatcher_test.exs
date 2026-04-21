defmodule Esr.Admin.DispatcherTest do
  @moduledoc """
  DI-7b Task 14b — Dispatcher secret redaction + telemetry coverage.

  `Esr.Admin.Commands.Notify` is the only wired-up kind at this phase,
  so we exercise the Dispatcher through a notify submission carrying
  secret-shaped args (app_secret / secret / token). The command itself
  ignores those fields (its contract is `to` + `text`), but the
  dispatcher must redact them with `"[redacted_post_exec]"` before the
  completed/<id>.yaml hits disk.

  Telemetry is asserted via `:telemetry.attach/4`: a successful
  dispatch must emit `[:esr, :admin, :command_executed]` with
  `kind`, `submitted_by`, and `duration_ms` in the measurements or
  metadata. A cap-check failure must emit `[:esr, :admin, :command_failed]`.

  Setup mirrors `Commands.NotifyTest` — disposable tmp ESRD_HOME, a
  wildcard grant for the test principal, and a best-effort restart of
  `Esr.Admin.Supervisor` so `Esr.Admin.Dispatcher` is alive before we
  cast into it.
  """

  use ExUnit.Case, async: false

  alias Esr.Admin.Dispatcher
  alias Esr.AdapterHub.Registry, as: HubRegistry
  alias Esr.Capabilities.Grants

  @test_principal "ou_dispatcher_test"

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "admin_disp_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(tmp, "default/admin_queue/pending"))
    File.mkdir_p!(Path.join(tmp, "default/admin_queue/processing"))
    File.mkdir_p!(Path.join(tmp, "default/admin_queue/completed"))
    File.mkdir_p!(Path.join(tmp, "default/admin_queue/failed"))

    prev_home = System.get_env("ESRD_HOME")
    System.put_env("ESRD_HOME", tmp)

    prior_grants = snapshot_grants()
    Grants.load_snapshot(Map.put(prior_grants, @test_principal, ["*"]))

    # Clean any leftover bindings so the first feishu topic we bind
    # below is unambiguously our test topic.
    for {topic, _} <- HubRegistry.list(), do: HubRegistry.unbind(topic)

    ensure_admin_dispatcher()

    on_exit(fn ->
      for {topic, _} <- HubRegistry.list(), do: HubRegistry.unbind(topic)
      Grants.load_snapshot(prior_grants)

      if prev_home,
        do: System.put_env("ESRD_HOME", prev_home),
        else: System.delete_env("ESRD_HOME")

      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  defp ensure_admin_dispatcher do
    if Process.whereis(Esr.Admin.Dispatcher) == nil do
      _ = Supervisor.restart_child(Esr.Supervisor, Esr.Admin.Supervisor)

      if Process.whereis(Esr.Admin.Dispatcher) == nil do
        {:ok, _} = Esr.Admin.Supervisor.start_link([])
      end
    end

    :ok
  end

  describe "secret redaction on queue file write" do
    test "redacts args.app_secret in completed/<id>.yaml", %{tmp: tmp} do
      topic = "adapter:feishu/redact_app_#{System.unique_integer([:positive])}"
      :ok = HubRegistry.bind(topic, "feishu-app:redact")
      :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, topic)

      id = "01ARZREDACT#{System.unique_integer([:positive])}"
      pending = Path.join([tmp, "default/admin_queue/pending", "#{id}.yaml"])
      completed = Path.join([tmp, "default/admin_queue/completed", "#{id}.yaml"])

      File.write!(pending, "id: #{id}\nkind: notify\n")

      command = %{
        "id" => id,
        "kind" => "notify",
        "submitted_by" => @test_principal,
        "args" => %{
          "to" => "ou_receiver",
          "text" => "hello",
          "app_secret" => "plain_app_secret_value"
        }
      }

      GenServer.cast(
        Dispatcher,
        {:execute, command, {:reply_to, {:file, completed}}}
      )

      assert wait_for_file(completed, 2_000), "expected #{completed} to exist"

      {:ok, doc} = YamlElixir.read_from_file(completed)
      assert doc["args"]["app_secret"] == "[redacted_post_exec]"
      # Non-secret args are untouched.
      assert doc["args"]["to"] == "ou_receiver"
      assert doc["args"]["text"] == "hello"
    end

    test "redacts secret and token args in completed/<id>.yaml", %{tmp: tmp} do
      topic = "adapter:feishu/redact_all_#{System.unique_integer([:positive])}"
      :ok = HubRegistry.bind(topic, "feishu-app:redact-all")
      :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, topic)

      id = "01ARZALLSEC#{System.unique_integer([:positive])}"
      pending = Path.join([tmp, "default/admin_queue/pending", "#{id}.yaml"])
      completed = Path.join([tmp, "default/admin_queue/completed", "#{id}.yaml"])

      File.write!(pending, "id: #{id}\nkind: notify\n")

      command = %{
        "id" => id,
        "kind" => "notify",
        "submitted_by" => @test_principal,
        "args" => %{
          "to" => "ou_receiver",
          "text" => "hello",
          "secret" => "plain_secret",
          "token" => "plain_token"
        }
      }

      GenServer.cast(
        Dispatcher,
        {:execute, command, {:reply_to, {:file, completed}}}
      )

      assert wait_for_file(completed, 2_000)

      {:ok, doc} = YamlElixir.read_from_file(completed)
      assert doc["args"]["secret"] == "[redacted_post_exec]"
      assert doc["args"]["token"] == "[redacted_post_exec]"
    end

    test "redacts args.token in failed/<id>.yaml on cap-check failure", %{tmp: tmp} do
      id = "01ARZFAILSEC#{System.unique_integer([:positive])}"
      pending = Path.join([tmp, "default/admin_queue/pending", "#{id}.yaml"])
      failed = Path.join([tmp, "default/admin_queue/failed", "#{id}.yaml"])
      completed = Path.join([tmp, "default/admin_queue/completed", "#{id}.yaml"])

      File.write!(pending, "id: #{id}\nkind: notify\n")

      # Principal not in Grants — cap-check denies.
      command = %{
        "id" => id,
        "kind" => "notify",
        "submitted_by" => "ou_nobody_redact",
        "args" => %{
          "to" => "ou_x",
          "text" => "y",
          "token" => "plain_token_on_failed_path"
        }
      }

      GenServer.cast(
        Dispatcher,
        {:execute, command, {:reply_to, {:file, completed}}}
      )

      assert wait_for_file(failed, 2_000), "expected failed file at #{failed}"

      {:ok, doc} = YamlElixir.read_from_file(failed)
      assert doc["args"]["token"] == "[redacted_post_exec]"
    end

    test "public helpers expose the sentinel and key list" do
      assert Dispatcher.redacted_post_exec() == "[redacted_post_exec]"
      assert Dispatcher.secret_arg_keys() == ["app_secret", "secret", "token"]
    end
  end

  describe "telemetry" do
    setup do
      handler_id = "test-dispatcher-telem-#{System.unique_integer([:positive])}"
      parent = self()

      :ok =
        :telemetry.attach_many(
          handler_id,
          [
            [:esr, :admin, :command_executed],
            [:esr, :admin, :command_failed]
          ],
          fn event, measurements, metadata, _cfg ->
            send(parent, {:telem, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "emits :command_executed with kind + submitted_by + duration_ms on success",
         %{tmp: tmp} do
      topic = "adapter:feishu/telem_ok_#{System.unique_integer([:positive])}"
      :ok = HubRegistry.bind(topic, "feishu-app:telem-ok")
      :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, topic)

      id = "01ARZTELEMOK#{System.unique_integer([:positive])}"
      pending = Path.join([tmp, "default/admin_queue/pending", "#{id}.yaml"])
      completed = Path.join([tmp, "default/admin_queue/completed", "#{id}.yaml"])

      File.write!(pending, "id: #{id}\nkind: notify\n")

      command = %{
        "id" => id,
        "kind" => "notify",
        "submitted_by" => @test_principal,
        "args" => %{"to" => "ou_receiver", "text" => "hello"}
      }

      GenServer.cast(
        Dispatcher,
        {:execute, command, {:reply_to, {:file, completed}}}
      )

      assert_receive {:telem,
                      [:esr, :admin, :command_executed],
                      %{count: 1, duration_ms: duration_ms},
                      %{kind: "notify", submitted_by: @test_principal}},
                     2_000

      assert is_integer(duration_ms)
      assert duration_ms >= 0
    end

    test "emits :command_failed with kind + submitted_by + duration_ms on cap-check denial",
         %{tmp: tmp} do
      id = "01ARZTELEMFAIL#{System.unique_integer([:positive])}"
      pending = Path.join([tmp, "default/admin_queue/pending", "#{id}.yaml"])
      completed = Path.join([tmp, "default/admin_queue/completed", "#{id}.yaml"])

      File.write!(pending, "id: #{id}\nkind: notify\n")

      command = %{
        "id" => id,
        "kind" => "notify",
        "submitted_by" => "ou_telem_nobody",
        "args" => %{"to" => "ou_x", "text" => "y"}
      }

      GenServer.cast(
        Dispatcher,
        {:execute, command, {:reply_to, {:file, completed}}}
      )

      assert_receive {:telem,
                      [:esr, :admin, :command_failed],
                      %{count: 1, duration_ms: _},
                      %{kind: "notify", submitted_by: "ou_telem_nobody"}},
                     2_000
    end
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

  defp snapshot_grants do
    :ets.tab2list(:esr_capabilities_grants) |> Map.new()
  rescue
    _ -> %{}
  end
end
