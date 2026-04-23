defmodule Esr.PyProcess do
  @moduledoc """
  Peer + OSProcess composition for Python sidecars.

  Protocol: JSON lines over stdin/stdout. Each request is a single-line
  JSON object `{"id": "...", "kind": "request", "payload": {...}}`;
  each reply is `{"id": "...", "kind": "reply", "payload": {...}}`.

  ## Wrapper mode

  Uses `wrapper: :plain` (erlexec without PTY). JSON-line sidecars don't
  need a controlling TTY; a plain stdin/stdout pair is both faster and
  less surprising (no pty echo, no `\\r\\n` line endings). BEAM-exit
  cleanup is provided by the erlexec port program, which kills children
  when the owning Erlang pid dies. See `Esr.OSProcess` moduledoc and
  `docs/notes/erlexec-migration.md`.

  See spec §3.2 and §8.3.
  """

  use Esr.Peer.Stateful
  use Esr.OSProcess, kind: :python, wrapper: :plain

  @doc """
  Start a Python sidecar peer.

  Args:
    * `:entry_point` (required) — one of
      * `{:module, "some.module"}` → `uv run python -m some.module`
      * `{:script, "/abs/path.py"}` → `uv run python /abs/path.py`
    * `:subscriber` (optional) — pid that receives `{:py_reply, decoded_map}`
      messages. Defaults to the caller of `start_link/1`.
  """
  def start_link(args) do
    args = Map.put_new(args, :subscriber, self())
    GenServer.start_link(__MODULE__.OSProcessWorker, args)
  end

  @doc """
  Encode a request map as a JSON line and write it to the sidecar's stdin.

  The `:id` key is required; `kind: "request"` is injected automatically.
  """
  def send_request(pid, %{id: _} = req) do
    line = Jason.encode!(Map.put(req, :kind, "request")) <> "\n"
    __MODULE__.OSProcessWorker.write_stdin(pid, line)
  end

  @impl Esr.Peer.Stateful
  def init(%{entry_point: entry_point} = args) do
    {:ok,
     %{
       entry_point: entry_point,
       subscribers: [args[:subscriber] || self()]
     }}
  end

  @impl Esr.Peer.Stateful
  def handle_upstream({:os_stdout, line}, state) do
    case Jason.decode(line) do
      {:ok, map} ->
        tuple = {:py_reply, map}
        Enum.each(state.subscribers, &send(&1, tuple))
        {:forward, [tuple], state}

      {:error, _} ->
        {:drop, :py_parse_error, state}
    end
  end

  def handle_upstream(_msg, state), do: {:forward, [], state}

  @impl Esr.Peer.Stateful
  def handle_downstream(_msg, state), do: {:forward, [], state}

  @impl Esr.OSProcess
  def os_cmd(state) do
    case state.entry_point do
      {:module, mod} -> ["uv", "run", "python", "-m", mod]
      {:script, path} -> ["uv", "run", "python", path]
    end
  end

  @impl Esr.OSProcess
  def os_env(_state), do: [{"PYTHONUNBUFFERED", "1"}]

  @impl Esr.OSProcess
  def on_os_exit(0, _state), do: {:stop, :normal}
  def on_os_exit(status, _state), do: {:stop, {:py_crashed, status}}
end
