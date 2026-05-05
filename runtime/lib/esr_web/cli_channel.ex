defmodule EsrWeb.CliChannel do
  @moduledoc """
  Phoenix.Channel for CLI control RPCs on ``cli:*`` topics (Phase 8c).

  The Python CLI opens a short-lived WS, joins a specific ``cli:<op>``
  topic, fires one ``cli_call`` event, and awaits the ``phx_reply``.
  Phase 8c base implementation echoes the payload so the full Python
  → Elixir → Python round-trip is verifiable without committing to
  specific control semantics; later iters replace the echo with the
  real dispatch table (cli:run → Topology.Registry.instantiate, etc.).
  """

  use Phoenix.Channel


  # Error shape returned by every cli:topology/* / cli:run/* / cli:stop/*
  # / cli:drain op now that Esr.Topology has been deleted (P3-13).
  # Maps to the CLI's data.get("error") path — user sees the migration
  # message and can follow the `/new-session` + `/list-sessions` flow.

  @impl Phoenix.Channel
  def join("cli:" <> _op = topic, _payload, socket) do
    {:ok, assign(socket, :topic, topic)}
  end

  def join(_topic, _payload, _socket) do
    {:error, %{reason: "invalid topic"}}
  end

  @impl Phoenix.Channel
  def handle_in("cli_call", payload, socket) do
    {:reply, {:ok, dispatch(socket.assigns.topic, payload)}, socket}
  end

  def handle_in(event, _payload, socket) do
    {:reply, {:error, %{reason: "unhandled event: #{event}"}}, socket}
  end

  @doc false
  @spec dispatch(String.t(), map()) :: map()
  def dispatch("cli:actors/list", _payload) do
    data =
      Esr.Entity.Registry.list_all()
      |> Enum.map(fn {actor_id, pid} ->
        %{"actor_id" => actor_id, "pid" => inspect(pid)}
      end)

    %{"data" => data}
  end

  # 2026-05-05 cli-channel→slash migration: cli:actors/tree and
  # cli:actors/inspect migrated to Esr.Commands.Actors.{Tree,Inspect}.
  # actors/tree got a real implementation (groups by session_id parsed
  # from actor_id; replaces the P3-13 stub that returned empty topologies).

  # 2026-05-05 cli-channel→slash migration: cli:run/<name>,
  # cli:stop/<name>, cli:drain dispatch clauses deleted. They had been
  # P3-13 placeholder error returners (the old Esr.Topology registry
  # was deleted then); operators have used /new-session + /end-session
  # for ~6 months. Python CLI's `esr cmd run/stop/drain` are also
  # deleted in this same PR. See docs/notes/2026-05-05-cli-channel-migration.md.

  # PR-21β 2026-04-30: cli:daemon/cleanup_orphans removed — erlexec owns
  # subprocess lifecycle so orphan accumulation is no longer possible.
  # `esr daemon doctor` keeps reporting workers_tracked but the on-demand
  # cleanup flag is gone too.

  # PR-21m: comprehensive runtime health snapshot for `esr daemon doctor`.
  # Pulls together state from multiple subsystems so operators can see
  # at a glance what's healthy / what's degraded.
  def dispatch("cli:daemon/doctor", _payload) do
    workers = Esr.WorkerSupervisor.list()
    user_count = length(Esr.Entity.User.Registry.list())

    workspace_count =
      try do
        length(Esr.Resource.Workspace.Registry.list())
      rescue
        _ -> 0
      end

    %{
      "data" => %{
        "esrd_pid" => System.pid() |> to_string(),
        "users_loaded" => user_count,
        "workspaces_loaded" => workspace_count,
        "workers_tracked" => length(workers),
        "workers" =>
          Enum.map(workers, fn {kind, name, id, pid} ->
            %{"kind" => to_string(kind), "name" => name, "id" => id, "pid" => pid}
          end)
      }
    }
  end

  # 2026-05-05 cli-channel→slash migration: cli:debug/{pause,resume}
  # migrated to Esr.Commands.Debug.{Pause,Resume}.

  # 2026-05-05 cli-channel→slash migration: cli:deadletter/{list,flush}
  # migrated to Esr.Commands.Deadletter.{List,Flush}. Bodies deleted —
  # see docs/notes/2026-05-05-cli-channel-migration.md.

  # 2026-05-05 cli-channel→slash migration: cli:adapter/start/<type>
  # migrated to Esr.Commands.Adapter.Start.

  # 2026-05-05 cli-channel→slash migration: cli:trace migrated to
  # Esr.Commands.Trace.

  # 2026-05-05 cli-channel→slash migration: cli:workspaces/describe
  # migrated to Esr.Commands.Workspace.Describe. The MCP-tool path
  # (Esr.Entity.Server.build_emit_for_tool("describe_topology", …))
  # now also delegates to Esr.Resource.Workspace.Describe, so the
  # security-boundary allowlist has a single source of truth.

  # 2026-05-05 cli-channel→slash migration: cli:adapters/{refresh,remove,
  # rename} migrated to Esr.Commands.Adapter.{Refresh,Remove,Rename}.
  # The `read_adapters_yaml` private helper that backed remove+rename is
  # now inlined in each command module.

  def dispatch("cli:workspace/register", payload) do
    alias Esr.Resource.Workspace.Registry, as: WorkspacesReg

    name = Map.get(payload, "name")

    if is_binary(name) and name != "" do
      ws = %WorkspacesReg.Workspace{
        name: name,
        # PR-22 (2026-04-29): `root` removed from workspace; per-session
        # arg now. Pre-PR-22 CLI clients still send root in payload —
        # we silently drop it for forward-compat.
        owner: payload["owner"],
        start_cmd: payload["start_cmd"] || "",
        role: payload["role"] || "dev",
        chats: payload["chats"] || [],
        env: payload["env"] || %{},
        # PR-C 2026-04-27: neighbors round-trip
        neighbors: payload["neighbors"] || [],
        # PR-F 2026-04-28: metadata round-trip — without this, registering
        # a workspace via CLI would silently drop the business-topology
        # context that `describe_topology` tool expects.
        metadata: payload["metadata"] || %{}
      }

      :ok = WorkspacesReg.put(ws)
      %{"data" => %{"ok" => true, "name" => name}}
    else
      %{"data" => %{"ok" => false, "reason" => "missing name"}}
    end
  end

  def dispatch(topic, _payload) do
    # Closes reviewer-C2. Unknown topics surface as a structured error so
    # typos and not-yet-implemented dispatches (cli:debug/replay,
    # cli:debug/inject, cli:deadletter/retry, cli:telemetry/<pat>,
    # cli:actors/logs) can't silently succeed with an echoing reply. Shape
    # matches every other dispatch ({"data" => ...}) so the CLI helpers
    # surface the error string via their existing data.get("error") paths.
    %{"data" => %{"error" => "unknown_topic: #{topic}"}}
  end

end
