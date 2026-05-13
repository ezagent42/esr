defmodule Esr.Integration.CcChannelStdioE2ETest do
  @moduledoc """
  Phase 8.1 (spec §8.3) integration test for the CC channel stdio
  bridge: BEAM (Phoenix endpoint + ChannelChannel) ↔ real
  `cc_channel_runner` Python subprocess ↔ MCP stdio frames on stdout.

  ## What this proves

  When a notification is broadcast on `cli:channel/<sid>` (which is
  exactly what `Esr.Plugins.ClaudeCode.CCProcess.broadcast_notification/2`
  does on every inbound text message), the Python bridge receives the
  envelope over its Phoenix WS subscription and emits a JSON-RPC
  `notifications/claude/channel` frame on its stdout. This pins the
  full architectural commitment of the 2026-05-13 stdio-bridge rev-7
  redesign: replace the broken HTTP MCP server with a stdio bridge
  spawned by CC, while keeping the inbound notification flow
  byte-for-byte compatible with Claude Code's
  `notifications/claude/channel` consumer.

  ## Why we re-enable the HTTP listener for the test

  `runtime/config/test.exs` sets `server: false` on the endpoint, so
  the default test suite never opens an HTTP port. The Python bridge
  is a real subprocess — it cannot use `Phoenix.ChannelTest`'s in-VM
  socket plumbing. We bring up an ephemeral-port HTTP listener for
  the duration of this test and tear it down on `on_exit/1`.

  ## Tags

  - `:slow` — requires Python venv + free port + ~3s for bridge to
    reach idle state. Excluded from the default `mix test` run.
  - `:integration` — also exercises the full app supervisor.

  Run via:

      MIX_ENV=test mix test test/esr/integration/cc_channel_stdio_e2e_test.exs \
        --include slow --include integration
  """

  use ExUnit.Case, async: false

  @moduletag :slow
  @moduletag :integration

  require Logger

  @bridge_boot_timeout_ms 5_000
  @frame_recv_timeout_ms 10_000

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

  test "notification broadcast on cli:channel/<sid> reaches bridge stdout as MCP frame", ctx do
    if ctx[:skip] do
      IO.puts("\n[cc_channel_stdio_e2e] SKIPPED: #{ctx[:reason]}")
      :ok
    else
      run_e2e(ctx)
    end
  end

  defp run_e2e(%{python_bin: python_bin, port: port}) do
    sid = "stdio-e2e-#{System.unique_integer([:positive])}"
    esrd_url = "ws://127.0.0.1:#{port}"

    bridge_port = spawn_bridge(python_bin, sid, esrd_url)

    try do
      assert wait_for_bridge_join(bridge_port, sid, @bridge_boot_timeout_ms),
             "bridge did not log phx_join ack within #{@bridge_boot_timeout_ms}ms"

      # Drive the MCP initialize handshake so the bridge's stdio loop
      # flips into the "ready to push notifications" state. Without
      # this, send_channel_notification logs "write_stream not ready"
      # and drops the params; the SDK only sets the write stream after
      # the initial JSON-RPC handshake completes.
      send_mcp_initialize(bridge_port)
      assert wait_for_initialize_ack(bridge_port, @bridge_boot_timeout_ms),
             "bridge did not reply to MCP initialize within #{@bridge_boot_timeout_ms}ms"

      send_mcp_initialized_notification(bridge_port)

      # Brief grace: the bridge's BridgeMCPServer.start runs initialize
      # → set self._write_stream → enter loop. The state transition is
      # synchronous but we have no observability beyond stderr logs.
      # 200ms is enough; if it isn't, the assertion below will time
      # out informatively.
      Process.sleep(200)

      envelope =
        %{
          "kind" => "notification",
          "content" => "hello from BEAM e2e",
          "chat_id" => "oc_e2e_#{System.unique_integer([:positive])}",
          "user" => "stdio_e2e_user",
          "source" => "feishu",
          "ts" => DateTime.utc_now() |> DateTime.to_iso8601()
        }

      :ok = broadcast_notification(sid, envelope)

      assert {:ok, frame} = await_channel_notification_frame(bridge_port, @frame_recv_timeout_ms),
             "expected a notifications/claude/channel frame on bridge stdout"

      assert frame["method"] == "notifications/claude/channel"
      params = frame["params"]
      assert is_map(params), "params must be a map; got: #{inspect(params)}"
      assert params["content"] == "hello from BEAM e2e"
      assert is_map(params["meta"])
      assert params["meta"]["chat_id"] == envelope["chat_id"]
      assert params["meta"]["user"] == "stdio_e2e_user"
    after
      _ = close_bridge(bridge_port)
    end
  end

  # -- bridge subprocess helpers -------------------------------------

  # Resolves the venv-installed python interpreter using the same
  # convention as Esr.Plugins.ClaudeCode.Launcher.python_bin_path/0:
  # `<repo>/py/.venv/bin/python`. Returns {:error, _} so the test can
  # skip cleanly on a runner where the venv isn't materialised.
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
    # Mirror Launcher.py_project_dir/0: app_dir(:esr) →
    # _build/test/lib/esr, drop 4, then "py".
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
        {:line, 65_536},
        args: [
          "-m",
          "cc_channel_runner",
          "--session-id",
          sid,
          "--esrd-url",
          esrd_url
        ],
        env: [
          # Ensure the bridge can import its module from py/src.
          {~c"PYTHONPATH", String.to_charlist(Path.join(py_project_dir(), "src"))}
        ]
      ]
    )
  end

  defp close_bridge(port) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    catch
      :error, :badarg -> :ok
    end
  end

  # The bridge writes:
  #   [cc_channel_runner sid=<8>] <time> INFO phx_join acked; starting MCP stdio loop + envelope dispatch
  # on stderr (we merged stderr → stdout). Wait for the substring.
  defp wait_for_bridge_join(port, _sid, timeout_ms) do
    wait_for_line(port, "phx_join acked", timeout_ms)
  end

  defp wait_for_initialize_ack(port, timeout_ms) do
    # Drain MCP stdout looking for a JSON-RPC reply to id=0
    # (initialize). The MCP SDK serializes responses as compact JSON
    # lines, which the bridge writes to stdout. With
    # `:stderr_to_stdout` we'll see both interleaved.
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_initialize_ack(port, deadline)
  end

  defp do_wait_for_initialize_ack(port, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      false
    else
      receive do
        {^port, {:data, {:eol, line}}} ->
          case parse_jsonrpc(line) do
            {:ok, %{"id" => 0, "result" => %{"capabilities" => _}}} -> true
            _ -> do_wait_for_initialize_ack(port, deadline)
          end

        {^port, {:data, {:noeol, _}}} ->
          do_wait_for_initialize_ack(port, deadline)

        {^port, _other} ->
          do_wait_for_initialize_ack(port, deadline)
      after
        remaining -> false
      end
    end
  end

  # Waits for a stderr/stdout line containing `needle`.
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
        {^port, {:data, {:eol, line}}} ->
          if line |> to_string() |> String.contains?(needle) do
            true
          else
            do_wait_for_line(port, needle, deadline)
          end

        {^port, {:data, {:noeol, _}}} ->
          do_wait_for_line(port, needle, deadline)

        {^port, _other} ->
          do_wait_for_line(port, needle, deadline)
      after
        remaining -> false
      end
    end
  end

  defp await_channel_notification_frame(port, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_channel_frame(port, deadline)
  end

  defp do_await_channel_frame(port, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      receive do
        {^port, {:data, {:eol, line}}} ->
          case parse_jsonrpc(line) do
            {:ok, %{"method" => "notifications/claude/channel"} = frame} ->
              {:ok, frame}

            _ ->
              do_await_channel_frame(port, deadline)
          end

        {^port, {:data, {:noeol, _}}} ->
          do_await_channel_frame(port, deadline)

        {^port, _other} ->
          do_await_channel_frame(port, deadline)
      after
        remaining -> {:error, :timeout}
      end
    end
  end

  defp parse_jsonrpc(line) when is_binary(line) or is_list(line) do
    bin = IO.iodata_to_binary([line])
    trimmed = String.trim(bin)

    case trimmed do
      "{" <> _ ->
        case Jason.decode(trimmed) do
          {:ok, decoded} -> {:ok, decoded}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  # -- MCP initialize handshake --------------------------------------

  defp send_mcp_initialize(port) do
    msg =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 0,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2024-11-05",
          "capabilities" => %{
            "experimental" => %{"claude/channel" => %{}},
            "roots" => %{"listChanged" => false},
            "sampling" => %{}
          },
          "clientInfo" => %{"name" => "stdio-e2e-test", "version" => "0.0.1"}
        }
      })

    Port.command(port, msg <> "\n")
  end

  defp send_mcp_initialized_notification(port) do
    msg =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized"
      })

    Port.command(port, msg <> "\n")
  end

  # -- BEAM-side broadcast -------------------------------------------

  defp broadcast_notification(sid, envelope) do
    Phoenix.PubSub.broadcast(
      EsrWeb.PubSub,
      "cli:channel/" <> sid,
      {:notification, envelope}
    )
  end

  # -- ephemeral HTTP listener (test-scoped) -------------------------

  # Phoenix endpoint defaults (test.exs) to server: false. For this
  # test we need a real HTTP listener so the Python subprocess can
  # open a WebSocket. We reconfigure + restart the endpoint child;
  # on_exit restores the prior config.
  defp start_http_listener do
    prior_endpoint = Application.get_env(:esr, EsrWeb.Endpoint, [])
    port = find_free_port()

    new_endpoint =
      prior_endpoint
      |> Keyword.put(:server, true)
      |> Keyword.put(:http, [ip: {127, 0, 0, 1}, port: port])

    Application.put_env(:esr, EsrWeb.Endpoint, new_endpoint)

    # If the endpoint child is already alive (typical: ExUnit started
    # the full app), terminate + restart it so it re-reads config.
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

    # Poll until the listener actually binds the port.
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

  defp find_free_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
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
