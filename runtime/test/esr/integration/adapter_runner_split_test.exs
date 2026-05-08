defmodule Esr.Integration.AdapterRunnerSplitTest do
  @moduledoc """
  P4b-9 — end-to-end check that `Esr.WorkerSupervisor.ensure_adapter/4`
  now routes through the per-type sidecars (`feishu_adapter_runner`,
  `cc_adapter_runner`, `generic_adapter_runner`). The
  `esr.ipc.adapter_runner` shim was hard-deleted in PR-5; the `refute`
  assertions below guard against regressions that would accidentally
  resurrect a monolith path.

  We don't need a full Phoenix-channel handshake here (adapter startup
  with a bad URL loops forever on reconnect backoff, and the unit-test
  suite already covers runner_core mechanics). The discriminating
  observable is the spawned process's command line: we see
  `python -m feishu_adapter_runner` for feishu and
  `python -m cc_adapter_runner` for the cc adapter.

  Tagged `:integration` because it genuinely fork/execs a Python
  subprocess. Defensive `on_exit` kills the child and clears pidfiles.
  """
  use ExUnit.Case, async: false


  alias Esr.WorkerSupervisor

  @bad_url "ws://127.0.0.1:65535/adapter_hub/socket/websocket?vsn=2.0.0"

  setup do
    # Kill any leftover workers from prior test runs.
    for {_kind, _name, _id, pid} <- WorkerSupervisor.list() do
      _ = System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    :ok
  end

  defp ps_command_line(pid) do
    # `ps -o command=` prints the argv without header. On macOS/Linux
    # the full command line is in the `command` column (truncated by
    # default to terminal width, but -o forces full output when piping).
    case System.cmd("ps", ["-p", Integer.to_string(pid), "-o", "command="],
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.trim(out)
      {_out, _code} -> ""
    end
  end

  defp await_alive(pid, budget_ms) do
    # PR-21β: ensure_adapter now spawns via Esr.OSProcess (erlexec).
    # The OS pid is reported synchronously; brief wait covers the
    # python interpreter import time.
    deadline = System.monotonic_time(:millisecond) + budget_ms

    Stream.repeatedly(fn ->
      case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
        {_, 0} -> :alive
        _ -> :dead
      end
    end)
    |> Enum.reduce_while(:not_yet, fn
      :alive, _ ->
        {:halt, :alive}

      :dead, _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:halt, :dead}
        else
          Process.sleep(100)
          {:cont, :not_yet}
        end
    end)
  end

  @tag :integration
  test "feishu adapter_name dispatches to feishu_adapter_runner module" do
    instance = "p4b9-feishu-#{System.unique_integer([:positive])}"

    try do
      result =
        WorkerSupervisor.ensure_adapter(
          "feishu",
          instance,
          %{"app_id" => "mock", "app_secret" => "mock"},
          @bad_url
        )

      assert result == :ok or match?({:error, _}, result)

      # If :ok, we have a live pid in the list. Give `uv run` time to
      # exec Python so `ps` sees the adapter command line.
      case Enum.find(WorkerSupervisor.list(), fn
             {:adapter, "feishu", ^instance, _pid} -> true
             _ -> false
           end) do
        {:adapter, "feishu", ^instance, pid} ->
          # Poll up to 5 s for the `uv` + Python exec to show the module
          # name. On a cold machine `uv` resolves the venv first.
          deadline = System.monotonic_time(:millisecond) + 5_000

          found? =
            Stream.repeatedly(fn -> ps_command_line(pid) end)
            |> Enum.reduce_while(false, fn cmd, _ ->
              cond do
                String.contains?(cmd, "feishu_adapter_runner") ->
                  {:halt, true}

                System.monotonic_time(:millisecond) >= deadline ->
                  {:halt, false}

                true ->
                  Process.sleep(200)
                  {:cont, false}
              end
            end)

          # The discriminating assertion: the PR-4a monolith path must
          # NOT appear in the spawned command line.
          final_cmd = ps_command_line(pid)
          refute String.contains?(final_cmd, "esr.ipc.adapter_runner")

          assert found?,
                 "expected `feishu_adapter_runner` in spawned argv, got: #{inspect(final_cmd)}"

        nil ->
          # Spawn was {:error, _} — acceptable for this smoke test on
          # machines where `uv` or `python` is unavailable. Flag clearly.
          assert match?({:error, _}, result),
                 "ensure_adapter returned :ok but no pid appeared in list/0"
      end
    after
      for {:adapter, "feishu", ^instance, pid} <- WorkerSupervisor.list() do
        _ = System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)
      end

      _ = File.rm("/tmp/esr-worker-adapter-feishu-#{instance}.pid")
    end
  end

  @tag :integration
  test "cc_mcp adapter_name dispatches to cc_adapter_runner module" do
    instance = "p4b9-ccpty-#{System.unique_integer([:positive])}"

    try do
      result =
        WorkerSupervisor.ensure_adapter(
          "cc_mcp",
          instance,
          %{"start_cmd" => "/bin/true"},
          @bad_url
        )

      assert result == :ok or match?({:error, _}, result)

      case Enum.find(WorkerSupervisor.list(), fn
             {:adapter, "cc_mcp", ^instance, _pid} -> true
             _ -> false
           end) do
        {:adapter, "cc_mcp", ^instance, pid} ->
          assert await_alive(pid, 5_000) == :alive

          deadline = System.monotonic_time(:millisecond) + 5_000

          found? =
            Stream.repeatedly(fn -> ps_command_line(pid) end)
            |> Enum.reduce_while(false, fn cmd, _ ->
              cond do
                String.contains?(cmd, "cc_adapter_runner") ->
                  {:halt, true}

                System.monotonic_time(:millisecond) >= deadline ->
                  {:halt, false}

                true ->
                  Process.sleep(200)
                  {:cont, false}
              end
            end)

          final_cmd = ps_command_line(pid)
          refute String.contains?(final_cmd, "esr.ipc.adapter_runner")

          assert found?,
                 "expected `cc_adapter_runner` in spawned argv, got: #{inspect(final_cmd)}"

        nil ->
          assert match?({:error, _}, result),
                 "ensure_adapter returned :ok but no pid appeared in list/0"
      end
    after
      for {:adapter, "cc_mcp", ^instance, pid} <- WorkerSupervisor.list() do
        _ = System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)
      end

      _ = File.rm("/tmp/esr-worker-adapter-cc_mcp-#{instance}.pid")
    end
  end
end
