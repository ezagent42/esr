defmodule Esr.Routing.SlashHandler do
  @moduledoc """
  Slash command parser — currently the only kind of message routing
  this module does. Forwards parsed commands to `Esr.Admin.Dispatcher`
  via cast+correlation-ref. Will be replaced by `Esr.Peers.SlashHandler`
  in the Peer/Session refactor (see
  `docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md`).

  GenServer that dispatches inbound Feishu `msg_received` envelopes
  (spec §6.5, dev-prod-isolation Task 17).

  Two paths:

    1. **Slash commands** (`/new-session`, `/switch-session`,
       `/end-session`, `/sessions` / `/list-sessions`, `/reload`) are
       parsed into the admin-command shape
       `%{"id" => _, "kind" => _, "submitted_by" => _, "args" => %{}}`
       and cast to `Esr.Admin.Dispatcher` with reply-to
       `{:pid, self(), ref}`. On `{:command_result, ref, result}`, the
       Router emits a Feishu `reply` directive via Phoenix.PubSub.

    2. **Non-command messages** are forwarded to the sender's active
       branch by looking up
       `routing["principals"][principal_id]["targets"][active]["esrd_url"]`
       in the on-disk `routing.yaml`, then broadcasting
       `{:forward, envelope}` on the PubSub topic `route:<esrd_url>`.
       Downstream esrd instances subscribe to their own `route:<url>`
       topic in a later task.

  ## PubSub name

  The Phoenix.PubSub name is `EsrWeb.PubSub` — the single PubSub server
  started in `Esr.Application`. The dev-prod-isolation spec references
  it as `Esr.PubSub` but the concrete registered name is `EsrWeb.PubSub`
  (see `application.ex:24`). Same divergence noted in
  `Esr.Admin.Commands.Notify`.

  ## State

      %__MODULE__{
        routing:       map(),  # parsed routing.yaml (or %{} if missing)
        branches:      map(),  # parsed branches.yaml (or %{} if missing)
        pending_refs:  map()   # ref → envelope (for correlating reply)
      }

  ## Subscription

  `init/1` subscribes to the `"msg_received"` topic. No producer is
  currently publishing on this topic — that publisher arrives in a
  later task (the Feishu adapter pushes inbound messages into the
  PeerServer today; a downstream fan-out to `msg_received` is still
  pending). Subscribing eagerly now means the Router is ready the
  moment the publisher is wired up.

  ## Hot-reload (Task 18)

  `init/1` also starts a `FileSystem` watch on
  `Esr.Paths.runtime_home()` and subscribes to `:file_event`. Whenever
  `routing.yaml` or `branches.yaml` in that directory change,
  `handle_info/2` reloads the corresponding state field in place. The
  watched directory is shared with `Esr.Capabilities.Watcher`
  (capabilities.yaml), so both watchers receive cross-fires for every
  write — we filter on `Path.basename/1` to stay scoped.

  ## ID generation

  `generate_id/0` uses 12 bytes of crypto-strong randomness encoded as
  unpadded Base32 — not a real ULID, but unique enough for the
  `admin_queue/pending/<id>.yaml` naming. Downstream Commands keyed by
  `submitted_by` and `kind` don't depend on ID ordering.
  """

  use GenServer
  require Logger

  defstruct routing: %{}, branches: %{}, pending_refs: %{}

  @pubsub EsrWeb.PubSub
  @msg_topic "msg_received"
  @reply_topic "feishu_reply"

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    runtime = Esr.Paths.runtime_home()
    scan_dir = Keyword.get(opts, :orphan_scan_dir, "/tmp")

    # Ensure the dir exists before we subscribe FileSystem to it —
    # fs_watch backends (FSEvents on macOS, inotify on Linux) need a
    # real directory to arm on. Missing = make it; Task 18 expects the
    # Router to self-heal.
    File.mkdir_p!(runtime)

    # Orphan /tmp/esrd-*/ reconciliation (spec §9.2, Task 22): must run
    # BEFORE fs_watch so branches.yaml mutations from the scan don't
    # fire spurious :file_event reloads on our still-empty in-memory
    # state.
    scan_orphan_esrd_dirs(scan_dir, runtime)

    state = %__MODULE__{
      routing: load_yaml(Path.join(runtime, "routing.yaml")),
      branches: load_yaml(Path.join(runtime, "branches.yaml"))
    }

    _ = Phoenix.PubSub.subscribe(@pubsub, @msg_topic)

    # fs_watch the runtime_home dir so writes to routing.yaml /
    # branches.yaml are hot-reloaded into state. Note that
    # `Esr.Capabilities.Watcher` also watches this same directory
    # (for capabilities.yaml); both will receive :file_event for every
    # file in the dir — basename filtering in handle_info/2 keeps
    # each watcher scoped to its own files.
    {:ok, fs_pid} = FileSystem.start_link(dirs: [runtime])
    FileSystem.subscribe(fs_pid)

    {:ok, state}
  end

  # ------------------------------------------------------------------
  # Msg-received dispatch
  # ------------------------------------------------------------------

  @impl true
  def handle_info({:msg_received, envelope}, state) when is_map(envelope) do
    text = get_in(envelope, ["payload", "args", "text"]) || ""

    case parse_command(text) do
      {:slash, kind, args} ->
        {:noreply, dispatch_slash(kind, args, envelope, state)}

      :not_command ->
        route_to_active(envelope, state)
        {:noreply, state}
    end
  end

  # Dispatcher reply — correlate by ref, emit reply, drop from state.
  @impl true
  def handle_info({:command_result, ref, result}, state) when is_reference(ref) do
    case Map.pop(state.pending_refs, ref) do
      {nil, _} ->
        # Unknown ref — log and ignore. Avoids crash if the Dispatcher
        # sends a stale result (e.g. Router was restarted between
        # cast and reply).
        Logger.warning("routing.slash_handler: unknown command_result ref — ignoring")

        {:noreply, state}

      {envelope, rest} ->
        emit_reply(envelope, format_result(result))
        {:noreply, %{state | pending_refs: rest}}
    end
  end

  # fs_watch hot-reload: either YAML changed on disk (e.g. Admin
  # Dispatcher writing a new session, an operator editing the file, a
  # post-merge hook syncing state) → refresh the in-memory copy. Cross-
  # fires from other files in the same dir (capabilities.yaml,
  # adapters.yaml, etc.) are ignored via basename filter.
  @impl true
  def handle_info({:file_event, _fs_pid, {path, _events}}, state) do
    state =
      case Path.basename(path) do
        "routing.yaml" -> %{state | routing: load_yaml(path)}
        "branches.yaml" -> %{state | branches: load_yaml(path)}
        _ -> state
      end

    {:noreply, state}
  end

  # FileSystem emits `:stop` when the watched dir disappears. No-op.
  def handle_info({:file_event, _fs_pid, :stop}, state), do: {:noreply, state}

  # Swallow unknown infos (e.g. late Phoenix.Socket.Broadcast frames
  # if anyone re-uses the topic for a different payload shape).
  def handle_info(_other, state), do: {:noreply, state}

  # ------------------------------------------------------------------
  # Parser — pure, public for test coverage
  # ------------------------------------------------------------------

  @typedoc "Outcome of parsing a message body against the slash grammar."
  @type parsed ::
          {:slash, kind :: String.t(), args :: map()}
          | :not_command

  @doc """
  Parse a message body into a slash-command tuple or `:not_command`.

  Leading whitespace is NOT stripped — the commands must start at
  column 0. This mirrors Slack/Feishu conventions and prevents
  accidental matches in quoted text.
  """
  @spec parse_command(String.t()) :: parsed()
  def parse_command("/new-session " <> rest), do: parse_session_new(rest)
  def parse_command("/switch-session " <> rest), do: parse_session_switch(rest)
  def parse_command("/end-session " <> rest), do: parse_session_end(rest)
  def parse_command("/sessions"), do: {:slash, "session_list", %{}}
  def parse_command("/list-sessions"), do: {:slash, "session_list", %{}}
  def parse_command("/reload"), do: {:slash, "reload", %{"acknowledge_breaking" => false}}
  def parse_command("/reload " <> rest), do: parse_reload(rest)
  def parse_command(_), do: :not_command

  # ------------------------------------------------------------------
  # Parser internals
  # ------------------------------------------------------------------

  defp parse_session_new(rest) do
    case tokenize(rest) do
      [branch | flags] ->
        {:slash, "session_new",
         %{"branch" => branch, "new_worktree" => "--new-worktree" in flags}}

      [] ->
        :not_command
    end
  end

  defp parse_session_switch(rest) do
    case tokenize(rest) do
      [branch | _] -> {:slash, "session_switch", %{"branch" => branch}}
      [] -> :not_command
    end
  end

  defp parse_session_end(rest) do
    case tokenize(rest) do
      [branch | flags] ->
        {:slash, "session_end", %{"branch" => branch, "force" => "--force" in flags}}

      [] ->
        :not_command
    end
  end

  defp parse_reload(rest) do
    flags = tokenize(rest)
    {:slash, "reload", %{"acknowledge_breaking" => "--acknowledge-breaking" in flags}}
  end

  defp tokenize(rest),
    do: rest |> String.trim() |> String.split(~r/\s+/, trim: true)

  # ------------------------------------------------------------------
  # Slash path — cast + ref storage
  # ------------------------------------------------------------------

  defp dispatch_slash(kind, args, envelope, state) do
    ref = make_ref()
    principal_id = envelope["principal_id"] || "ou_unknown"

    cmd = %{
      "id" => generate_id(),
      "kind" => kind,
      "submitted_by" => principal_id,
      "args" => args
    }

    GenServer.cast(
      Esr.Admin.Dispatcher,
      {:execute, cmd, {:reply_to, {:pid, self(), ref}}}
    )

    %{state | pending_refs: Map.put(state.pending_refs, ref, envelope)}
  end

  # ------------------------------------------------------------------
  # Non-command path — forward to the active branch's esrd_url
  # ------------------------------------------------------------------

  defp route_to_active(envelope, state) do
    principal_id = envelope["principal_id"]
    active = get_in(state.routing, ["principals", principal_id, "active"])

    target_url =
      active &&
        get_in(state.routing, ["principals", principal_id, "targets", active, "esrd_url"])

    if is_binary(target_url) and target_url != "" do
      Phoenix.PubSub.broadcast(@pubsub, "route:#{target_url}", {:forward, envelope})
    else
      Logger.debug(
        "routing.slash_handler: no active route for principal=#{inspect(principal_id)}"
      )
    end

    :ok
  end

  # ------------------------------------------------------------------
  # Reply emission — broadcast a Feishu `reply` directive
  # ------------------------------------------------------------------

  defp emit_reply(envelope, text) do
    chat_id = get_in(envelope, ["payload", "args", "chat_id"])

    directive = %{
      "kind" => "reply",
      "args" => %{"chat_id" => chat_id, "text" => text}
    }

    Phoenix.PubSub.broadcast(@pubsub, @reply_topic, {:directive, directive})
    :ok
  end

  # ------------------------------------------------------------------
  # Result formatting — human-readable text for the Feishu reply
  # ------------------------------------------------------------------

  defp format_result({:ok, %{"branch" => br, "port" => port}}),
    do: "session #{br} ready on port #{port}"

  defp format_result({:ok, %{"branches" => branches}}) when is_list(branches),
    do: "sessions: " <> Enum.join(branches, ", ")

  defp format_result({:ok, %{} = m}), do: "ok: " <> inspect(m)
  defp format_result({:ok, other}), do: "ok: " <> inspect(other)

  defp format_result({:error, %{"type" => "unauthorized"}}), do: "error: unauthorized"

  defp format_result({:error, %{"type" => type}}) when is_binary(type),
    do: "error: " <> type

  defp format_result({:error, other}), do: "error: " <> inspect(other)
  defp format_result(other), do: "result: " <> inspect(other)

  # ------------------------------------------------------------------
  # YAML loading — missing file → empty map (not an error)
  # ------------------------------------------------------------------

  defp load_yaml(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, m} when is_map(m) -> m
      _ -> %{}
    end
  end

  # ------------------------------------------------------------------
  # ID generation — 12 bytes, unpadded Base32. Unique enough for queue
  # file naming; not a real ULID (lexicographic-sortable by time).
  # ------------------------------------------------------------------

  defp generate_id,
    do: :crypto.strong_rand_bytes(12) |> Base.encode32(padding: false)

  # ------------------------------------------------------------------
  # Orphan /tmp/esrd-*/ scan (spec §9.2, Task 22)
  # ------------------------------------------------------------------
  #
  # For each dir matching `<scan_dir>/esrd-*/` that contains a
  # `default/esrd.pid` file (our "this is ours" marker — third-party
  # directories without the pidfile are skipped):
  #
  #   * pid alive  → ensure entry present in branches.yaml (adopt)
  #   * pid dead   → `File.rm_rf!` the dir + drop from branches.yaml
  #   * port file present → use that as `port` when adopting
  #
  # Runs synchronously in `init/1` before fs_watch starts so the
  # branches.yaml writes this performs don't trigger self-fired
  # :file_event callbacks on an empty in-memory state.
  defp scan_orphan_esrd_dirs(scan_dir, runtime) do
    branches_path = Path.join(runtime, "branches.yaml")

    candidates =
      case File.ls(scan_dir) do
        {:ok, entries} ->
          for name <- entries,
              String.starts_with?(name, "esrd-"),
              dir = Path.join(scan_dir, name),
              File.dir?(dir),
              pidfile = Path.join([dir, "default", "esrd.pid"]),
              File.regular?(pidfile),
              do: {name, dir, pidfile}

        _ ->
          []
      end

    Enum.each(candidates, fn {name, dir, pidfile} ->
      branch = String.replace_prefix(name, "esrd-", "")

      case read_pid(pidfile) do
        {:ok, pid} ->
          if pid_alive?(pid) do
            adopt_branch(branches_path, branch, dir)
          else
            drop_branch(branches_path, branch, dir)
          end

        :error ->
          # Malformed pidfile = treat as dead.
          drop_branch(branches_path, branch, dir)
      end
    end)

    :ok
  end

  defp read_pid(path) do
    case File.read(path) do
      {:ok, contents} ->
        case contents |> String.trim() |> Integer.parse() do
          {pid, _} when pid > 0 -> {:ok, pid}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  # POSIX `kill -0 <pid>` returns 0 iff the pid is alive and the caller
  # has permission to signal it. Matches the pattern used in
  # Esr.WorkerSupervisor.
  defp pid_alive?(pid) when is_integer(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  # Adopt: ensure branches.yaml has an entry for this branch. No-op if
  # already present (we don't clobber operator-maintained fields).
  defp adopt_branch(branches_path, branch, esrd_home_dir) do
    current = load_branches_map(branches_path)
    branches = Map.get(current, "branches") || %{}

    if Map.has_key?(branches, branch) do
      :ok
    else
      port = read_port(Path.join([esrd_home_dir, "default", "esrd.port"]))

      entry = %{
        "esrd_home" => esrd_home_dir,
        "port" => port,
        "status" => "running",
        "kind" => "ephemeral",
        "adopted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      updated = Map.put(current, "branches", Map.put(branches, branch, entry))
      _ = Esr.Yaml.Writer.write(branches_path, updated)
      :ok
    end
  end

  # Prune: rm_rf the dir and drop branches.<branch> from branches.yaml.
  defp drop_branch(branches_path, branch, dir) do
    _ = File.rm_rf!(dir)

    current = load_branches_map(branches_path)
    branches = Map.get(current, "branches") || %{}

    if Map.has_key?(branches, branch) do
      updated = Map.put(current, "branches", Map.delete(branches, branch))
      _ = Esr.Yaml.Writer.write(branches_path, updated)
    end

    :ok
  end

  defp load_branches_map(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{} = m} -> m
      _ -> %{"branches" => %{}}
    end
  end

  defp read_port(path) do
    with {:ok, contents} <- File.read(path),
         {port, _} <- contents |> String.trim() |> Integer.parse() do
      port
    else
      _ -> nil
    end
  end
end
