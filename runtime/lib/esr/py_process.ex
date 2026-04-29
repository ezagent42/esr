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

  @behaviour Esr.Role.State

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

  # Called by the generated OSProcessWorker.init/1 (not a GenServer
  # callback — this module doesn't `use GenServer` directly; the
  # generated OSProcessWorker child module does). Returns the initial
  # peer state.
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
  def os_cwd(state) do
    # `uv run python -m <pkg>` autodetects the project via cwd walk.
    # Modules live under `py/src/` so every sidecar must run from the
    # repo's `py/` directory; absolute `{:script, path}` entries don't
    # care but we set cwd unconditionally for consistency.
    #
    # `{:script, path}` with an absolute path takes precedence — running
    # from `py/` is harmless for those too.
    case state.entry_point do
      {:module, _} -> py_project_dir()
      {:script, _} -> py_project_dir()
    end
  end

  @impl Esr.OSProcess
  def on_os_exit(0, _state), do: {:stop, :normal}
  def on_os_exit(status, _state), do: {:stop, {:py_crashed, status}}

  # Resolve the repo's `py/` directory. App-env override
  # `config :esr, :py_project_dir, path` lets operators pin the path
  # (e.g. when running from an install prefix); default walks up from
  # `Application.app_dir/1` to find the sibling `py/` dir.
  defp py_project_dir do
    case Application.get_env(:esr, :py_project_dir) do
      path when is_binary(path) ->
        path

      _ ->
        # In a dev checkout `Application.app_dir(:esr)` resolves to
        # `.../runtime/_build/.../lib/esr`. Walk up to the repo root
        # and append `py`. If the walk fails we fall back to `../py`
        # relative to the current cwd (best-effort for mix test).
        try do
          app = Application.app_dir(:esr)
          # Walk up to the repo root. Typical chain is
          #   <repo>/runtime/_build/<env>/lib/esr  → 4 parents deep
          # the 5th is <repo>, then append `py`.
          repo = app |> Path.split() |> Enum.reverse() |> Enum.drop(4) |> Enum.reverse() |> Path.join()
          candidate = Path.join(repo, "py")
          if File.dir?(candidate), do: candidate, else: Path.expand("../py", File.cwd!())
        rescue
          _ -> Path.expand("../py", File.cwd!())
        end
    end
  end
end
