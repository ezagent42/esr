defmodule Esr.Lifecycle.CcChannelOrphanTest do
  @moduledoc """
  Phase 8.2 (spec §7) lifecycle invariants for the CC channel stdio
  bridge.

  ## Invariants (from spec §7 rev-7)

  | ID  | Invariant                                                        | Covered by                              |
  |-----|------------------------------------------------------------------|-----------------------------------------|
  | I-1 | BEAM hard-killed → every bridge exits within 5s (stdio EOF)      | `test/.../stdin EOF terminates bridge`  |
  | I-2 | `/session:end name=…` → that session's bridge exits within 5s    | follows I-1 (Port.close = stdin EOF)    |
  | I-3 | CC SIGKILL → bridge exits via stdio EOF within 5s                | follows I-1                              |
  | I-4 | BEAM-down while bridge alive → bridge retries 3× then exits      | py unit tests (test_cc_channel_runner_ws — Phase 8.2 future) |

  I-1 is the architectural commitment of the whole 2026-05-13 stdio-
  bridge rev-7 design: instead of a ppid watchdog or controlling-TTY
  SIGHUP, the bridge relies *exclusively* on the MCP stdio pipe
  closing to detect that its parent (claude) died. cc-openclaw's
  `channel_server/adapters/cc/channel.py` runs the same pattern in
  production without observed orphaning (spec §4 "Bridge lifecycle").

  This file pins I-1 with a real subprocess; I-2/I-3 are variants
  (the parent close path triggers the same EOF) so they don't earn
  separate tests. I-4 requires mocking the WS server's close
  behavior — that lives in `py/tests/test_cc_channel_runner_*.py`.

  ## Tags

  `@moduletag :slow` — spawns a real subprocess. Excluded from
  default `mix test`. Run via:

      MIX_ENV=test mix test test/esr/lifecycle/cc_channel_orphan_test.exs \
        --include slow
  """

  use ExUnit.Case, async: false

  @moduletag :slow

  @bridge_exit_timeout_ms 5_000

  setup do
    case ensure_python_venv() do
      {:ok, python_bin} ->
        {:ok, listener_state} = start_http_listener()
        on_exit(fn -> stop_http_listener(listener_state) end)
        {:ok, python_bin: python_bin, port: listener_state.port}

      {:error, reason} ->
        {:ok, skip: true, reason: reason}
    end
  end

  test "I-1: closing the bridge's stdin causes the bridge process to exit", ctx do
    if ctx[:skip] do
      IO.puts("\n[cc_channel_orphan I-1] SKIPPED: #{ctx[:reason]}")
      :ok
    else
      run_i1(ctx)
    end
  end

  defp run_i1(%{python_bin: python_bin, port: port}) do
    sid = "orphan-i1-#{System.unique_integer([:positive])}"
    esrd_url = "ws://127.0.0.1:#{port}"

    bridge_port = spawn_bridge(python_bin, sid, esrd_url)

    # Stash the OS pid before we Port.close — once the port is closed
    # we can't read it back. Capture via :erlang.port_info/2 because
    # Port.open doesn't expose it on the return value.
    {:os_pid, os_pid} = Port.info(bridge_port, :os_pid)

    # Wait until the bridge logs phx_join ack — proves it reached the
    # `asyncio.wait({mcp_task, recv_task})` line in __main__.py. Before
    # that, the bridge is busy in `client.connect()` and stdin EOF
    # can't propagate. Without this, the test would race a 1s asyncio
    # backoff against the 5s exit timeout.
    assert wait_for_line(bridge_port, "phx_join acked", 5_000),
           "bridge did not reach idle state (phx_join ack) within 5s"

    assert os_pid_alive?(os_pid),
           "bridge OS process (pid=#{os_pid}) should be alive after spawn"

    # Close the BEAM side of the port. The :spawn_executable port maps
    # `Port.close` to closing both the read and write pipes to the
    # subprocess. Python's stdio loop reads EOF on stdin and the
    # asyncio context exits — see py/src/cc_channel_runner/__main__.py.
    true = Port.close(bridge_port)

    assert wait_for_os_pid_exit(os_pid, @bridge_exit_timeout_ms),
           "bridge OS process (pid=#{os_pid}) did not exit within " <>
             "#{@bridge_exit_timeout_ms}ms of stdin close — spec I-1 violated"
  end

  defp wait_for_line(port, needle, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_line(port, needle, deadline)
  end

  defp do_wait_for_line(port, needle, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      false
    else
      receive do
        {^port, {:data, data}} ->
          chunk = IO.iodata_to_binary([data])

          if String.contains?(chunk, needle) do
            true
          else
            do_wait_for_line(port, needle, deadline)
          end

        {^port, _other} ->
          do_wait_for_line(port, needle, deadline)
      after
        remaining -> false
      end
    end
  end

  # -- helpers -------------------------------------------------------

  defp ensure_python_venv do
    py_dir = py_project_dir()
    candidate = Path.join(py_dir, ".venv/bin/python")

    cond do
      not File.dir?(py_dir) ->
        {:error, "py project dir not found at #{py_dir}"}

      not File.exists?(candidate) ->
        {:error, "venv python not found at #{candidate} (run `uv sync --project py`)"}

      true ->
        {:ok, candidate}
    end
  end

  defp py_project_dir do
    try do
      app = Application.app_dir(:esr)
      repo = app |> Path.split() |> Enum.reverse() |> Enum.drop(4) |> Enum.reverse() |> Path.join()
      candidate = Path.join(repo, "py")
      if File.dir?(candidate), do: candidate, else: Path.expand("../py", File.cwd!())
    rescue
      _ -> Path.expand("../py", File.cwd!())
    end
  end

  defp spawn_bridge(python_bin, sid, esrd_url) do
    Port.open(
      {:spawn_executable, python_bin},
      [
        :binary,
        :stderr_to_stdout,
        args: [
          "-m",
          "cc_channel_runner",
          "--session-id",
          sid,
          "--esrd-url",
          esrd_url
        ],
        env: [
          {~c"PYTHONPATH", String.to_charlist(Path.join(py_project_dir(), "src"))}
        ]
      ]
    )
  end

  defp os_pid_alive?(os_pid) when is_integer(os_pid) do
    case System.cmd("ps", ["-p", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp wait_for_os_pid_exit(os_pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_os_pid_exit(os_pid, deadline)
  end

  defp do_wait_for_os_pid_exit(os_pid, deadline) do
    cond do
      not os_pid_alive?(os_pid) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(100)
        do_wait_for_os_pid_exit(os_pid, deadline)
    end
  end

  defp find_free_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  # -- ephemeral Phoenix HTTP listener (test-scoped) -----------------
  # See cc_channel_stdio_e2e_test.exs for the rationale: the test
  # config sets server: false; the bridge is a real subprocess and
  # cannot use Phoenix.ChannelTest's in-VM transport, so we re-enable
  # the listener on an ephemeral port for the duration of the test.

  defp start_http_listener do
    prior_endpoint = Application.get_env(:esr, EsrWeb.Endpoint, [])
    port = find_free_port()

    new_endpoint =
      prior_endpoint
      |> Keyword.put(:server, true)
      |> Keyword.put(:http, [ip: {127, 0, 0, 1}, port: port])

    Application.put_env(:esr, EsrWeb.Endpoint, new_endpoint)

    case Supervisor.terminate_child(Esr.Supervisor, EsrWeb.Endpoint) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    case Supervisor.restart_child(Esr.Supervisor, EsrWeb.Endpoint) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, :running} -> :ok
      other -> raise "could not restart EsrWeb.Endpoint: #{inspect(other)}"
    end

    unless wait_for_port(port, 5_000) do
      raise "Phoenix endpoint did not start listening on port #{port}"
    end

    {:ok, %{port: port, prior_endpoint: prior_endpoint}}
  end

  defp stop_http_listener(%{prior_endpoint: prior}) do
    _ = Supervisor.terminate_child(Esr.Supervisor, EsrWeb.Endpoint)
    Application.put_env(:esr, EsrWeb.Endpoint, prior)
    _ = Supervisor.restart_child(Esr.Supervisor, EsrWeb.Endpoint)
    :ok
  end

  defp wait_for_port(port, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_port(port, deadline)
  end

  defp do_wait_for_port(port, deadline) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 100) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        true

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          false
        else
          Process.sleep(50)
          do_wait_for_port(port, deadline)
        end
    end
  end
end
