defmodule Esr.WorkerSupervisorTest do
  @moduledoc """
  PR-21β 2026-04-30 — Esr.WorkerSupervisor as a thin GenServer over an
  internal DynamicSupervisor of `Esr.Workers.{AdapterProcess,HandlerProcess}`
  children. Tests cover idempotency + tracking surface; subprocess
  lifecycle is covered by the per-peer test suites and the integration
  tests below.
  """

  use ExUnit.Case, async: false

  alias Esr.WorkerSupervisor

  setup do
    Application.put_env(:esr, :spawn_token, "test-token-#{System.unique_integer()}")
    on_exit(fn -> Application.delete_env(:esr, :spawn_token) end)

    # Best-effort cleanup of any tracked workers leaked from a previous
    # test. With erlexec, supervisor termination cascades to children,
    # so this is just for state isolation between tests.
    for {kind, name, id, _pid} <- WorkerSupervisor.list() do
      if kind == :adapter, do: WorkerSupervisor.terminate_adapter(name, id)
    end

    :ok
  end

  describe "sidecar_module/1" do
    test "known adapters dispatch to dedicated sidecars" do
      assert WorkerSupervisor.sidecar_module("feishu") == "feishu_adapter_runner"
      assert WorkerSupervisor.sidecar_module("cc_tmux") == "cc_adapter_runner"
      assert WorkerSupervisor.sidecar_module("cc_mcp") == "cc_adapter_runner"
    end

    test "unknown adapter names fall back to generic_adapter_runner" do
      assert WorkerSupervisor.sidecar_module("unknown_thing") == "generic_adapter_runner"
      assert WorkerSupervisor.sidecar_module("brand_new_adapter") == "generic_adapter_runner"
    end
  end

  describe "ensure_adapter/4 idempotency" do
    test "second call with same key returns :already_running" do
      key_name = "noop_adapter_#{System.unique_integer([:positive])}"
      instance = "inst_#{System.unique_integer([:positive])}"
      url = "ws://127.0.0.1:65535/adapter_hub/socket/websocket?vsn=2.0.0"

      try do
        first = WorkerSupervisor.ensure_adapter(key_name, instance, %{}, url)
        assert first == :ok

        # Second call: the child is alive (subprocess may be busy
        # failing to connect, but the BEAM peer is up).
        second = WorkerSupervisor.ensure_adapter(key_name, instance, %{}, url)
        assert second == :already_running

        # list/0 contains exactly one entry for this key.
        matching =
          Enum.count(WorkerSupervisor.list(), fn
            {:adapter, ^key_name, ^instance, _pid} -> true
            _ -> false
          end)

        assert matching == 1
      after
        WorkerSupervisor.terminate_adapter(key_name, instance)
      end
    end
  end

  describe "ensure_handler/3" do
    test "tracks the key in list/0 and returns :ok" do
      module = "noop_module_#{System.unique_integer([:positive])}"
      worker_id = "w_#{System.unique_integer([:positive])}"
      url = "ws://127.0.0.1:65535/handler_hub/socket/websocket?vsn=2.0.0"

      try do
        result = WorkerSupervisor.ensure_handler(module, worker_id, url)
        assert result == :ok

        assert Enum.any?(WorkerSupervisor.list(), fn
                 {:handler, ^module, ^worker_id, pid} -> is_pid(pid)
                 _ -> false
               end)

        # Idempotency
        assert WorkerSupervisor.ensure_handler(module, worker_id, url) == :already_running
      after
        for {:handler, ^module, ^worker_id, pid} <- WorkerSupervisor.list() do
          if Process.alive?(pid), do: GenServer.stop(pid, :shutdown, 1_000)
        end
      end
    end
  end

  describe "terminate_adapter/2" do
    test "live key → :ok, removes from list" do
      key_name = "term_adapter_#{System.unique_integer([:positive])}"
      instance = "i_#{System.unique_integer([:positive])}"
      url = "ws://127.0.0.1:65535/adapter_hub/socket/websocket?vsn=2.0.0"

      :ok = WorkerSupervisor.ensure_adapter(key_name, instance, %{}, url)
      assert :ok = WorkerSupervisor.terminate_adapter(key_name, instance)

      refute Enum.any?(WorkerSupervisor.list(), fn
               {:adapter, ^key_name, ^instance, _pid} -> true
               _ -> false
             end)
    end

    test "absent key → :not_found" do
      assert :not_found = WorkerSupervisor.terminate_adapter("nope", "missing")
    end
  end

  describe "list/0" do
    test "returns BEAM pids (PR-21β: switched from OS pids)" do
      assert is_list(WorkerSupervisor.list())

      Enum.each(WorkerSupervisor.list(), fn {kind, name, id, pid} ->
        assert kind in [:adapter, :handler]
        assert is_binary(name) and is_binary(id)
        assert is_pid(pid)
      end)
    end
  end
end
