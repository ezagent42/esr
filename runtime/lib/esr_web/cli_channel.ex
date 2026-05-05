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

  alias Esr.Telemetry.Buffer
  alias Esr.Telemetry.Buffer.Event, as: TelemetryEvent

  # Error shape returned by every cli:topology/* / cli:run/* / cli:stop/*
  # / cli:drain op now that Esr.Topology has been deleted (P3-13).
  # Maps to the CLI's data.get("error") path — user sees the migration
  # message and can follow the `/new-session` + `/list-sessions` flow.
  @topology_removed_error "topology module removed — use /new-session + /list-sessions"

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

  def dispatch("cli:actors/tree", _payload) do
    # P3-13: Topology module deleted. The "tree" view used to group
    # Entity.Registry entries by their Topology handle; without that
    # registry we can still surface the raw actor list so the CLI
    # remains useful, and return an empty topologies list.
    %{"data" => %{"topologies" => [], "error" => @topology_removed_error}}
  end

  def dispatch(
        "cli:actors/inspect",
        %{"arg" => actor_id, "field" => field}
      )
      when is_binary(actor_id) and is_binary(field) do
    case Esr.Entity.Registry.lookup(actor_id) do
      {:ok, _pid} ->
        snap = Esr.Entity.Server.describe(actor_id)
        data = %{"actor_id" => snap.actor_id, "state" => stringify_keys(snap.state)}
        path = String.split(field, ".")

        case get_in_nested(data, path) do
          nil ->
            %{
              "data" => %{
                "error" => "field not present",
                "field" => field,
                "actor_id" => actor_id
              }
            }

          value ->
            %{
              "data" => %{
                "actor_id" => actor_id,
                "field" => field,
                "value" => value
              }
            }
        end

      :error ->
        %{"data" => %{"error" => "actor not found", "actor_id" => actor_id}}
    end
  end

  def dispatch("cli:actors/inspect", %{"arg" => actor_id}) when is_binary(actor_id) do
    case Esr.Entity.Registry.lookup(actor_id) do
      {:ok, _pid} ->
        snap = Esr.Entity.Server.describe(actor_id)

        data = %{
          "actor_id" => snap.actor_id,
          "actor_type" => snap.actor_type,
          "handler_module" => snap.handler_module,
          "paused" => snap.paused,
          "state" => stringify_keys(snap.state)
        }

        # Augment with chat_ids from AdapterSocketRegistry if this actor is a
        # cc_proxy / feishu_thread_proxy etc tracked there.
        session_ctx =
          case Esr.Resource.AdapterSocket.Registry.lookup(actor_id_strip_prefix(snap.actor_id)) do
            {:ok, row} ->
              %{
                "chat_ids" => row.chat_ids,
                "default_chat_id" => List.first(row.chat_ids) || ""
              }

            :error ->
              %{}
          end

        data = Map.merge(data, session_ctx)
        %{"data" => data}

      :error ->
        %{"data" => %{"error" => "actor not found", "actor_id" => actor_id}}
    end
  end

  def dispatch("cli:actors/inspect", _payload) do
    %{"data" => %{"error" => "missing 'arg' (actor_id)"}}
  end

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

  def dispatch("cli:adapter/start/" <> adapter_type, payload) when is_binary(adapter_type) do
    instance_id = Map.get(payload, "instance_id")
    config = Map.get(payload, "config") || %{}

    if is_binary(instance_id) and instance_id != "" do
      url =
        "ws://127.0.0.1:" <>
          Integer.to_string(phoenix_port()) <>
          "/adapter_hub/socket/websocket?vsn=2.0.0"

      case Esr.WorkerSupervisor.ensure_adapter(adapter_type, instance_id, config, url) do
        :ok -> %{"data" => %{"ok" => true, "spawned" => true}}
        :already_running -> %{"data" => %{"ok" => true, "spawned" => false}}
        {:error, reason} -> %{"data" => %{"ok" => false, "reason" => inspect(reason)}}
      end
    else
      %{"data" => %{"ok" => false, "reason" => "instance_id missing"}}
    end
  end

  def dispatch("cli:trace", payload) do
    duration_s =
      case Map.get(payload, "duration_seconds") do
        n when is_integer(n) -> n
        _ -> 900
      end

    entries =
      :default
      |> Buffer.query(duration_seconds: duration_s)
      |> Enum.map(&serialise_telemetry_event/1)

    %{"entries" => entries}
  end

  # PR-F 2026-04-28: business-topology MCP tool reads via this dispatch.
  # Returns the current workspace's filtered metadata (allowlist:
  # name, role, chats, neighbors_declared, metadata) plus 1-hop
  # neighbour workspaces resolved from `Workspace.neighbors` entries
  # of form `workspace:<name>`. Operational fields (cwd, env,
  # start_cmd) are filtered out by `filter_workspace/1` — they're
  # for the runtime, not for the LLM. Spec
  # `docs/superpowers/specs/2026-04-28-business-topology-mcp-tool.md`.
  def dispatch("cli:workspaces/describe", %{"arg" => workspace_name})
      when is_binary(workspace_name) do
    alias Esr.Resource.Workspace.Registry, as: WorkspacesReg

    case WorkspacesReg.get(workspace_name) do
      {:ok, ws} ->
        neighbours = resolve_neighbour_workspaces(ws)

        %{"data" => %{
            "current_workspace" => filter_workspace_for_llm(ws),
            "neighbor_workspaces" => Enum.map(neighbours, &filter_workspace_for_llm/1)
          }}

      :error ->
        %{"data" => %{"error" => "unknown_workspace: #{workspace_name}"}}
    end
  end

  def dispatch("cli:workspaces/describe", _payload) do
    %{"data" => %{"error" => "missing arg: workspace_name"}}
  end

  # PR-K 2026-04-28 / fixed in PR-L: re-run the boot-time adapters
  # bootstrap without an esrd restart so `esr adapter add` can spawn
  # both halves of a feishu instance — the Python adapter sidecar
  # (via WorkerSupervisor.ensure_adapter) AND the FAA peer (via
  # Scope.Admin.bootstrap_feishu_app_adapters). PR-K shipped only
  # the FAA half; the missing Python subprocess made
  # ESR开发助手's first add appear partial. Both calls are idempotent.
  def dispatch("cli:adapters/refresh", _payload) do
    # PR-M: don't pattern-match `:ok =` — restore_adapters_from_disk
    # returns the list of for-loop results when adapters.yaml has
    # entries, not the atom `:ok`. Drop the return value entirely.
    _ = Esr.Application.restore_adapters_from_disk(Esr.Paths.esrd_home())
    _ = Esr.Plugins.Feishu.Bootstrap.bootstrap()
    %{"data" => %{"ok" => true}}
  end

  # PR-L 2026-04-28: counterpart to cli:adapters/refresh — operator
  # wants to remove an adapter. Three steps in this order:
  #   1. Terminate the Python sidecar (WorkerSupervisor.terminate_adapter)
  #   2. Terminate the Elixir FAA peer (Scope.Admin.terminate_feishu_app_adapter)
  #   3. Remove the entry from adapters.yaml (so a future esrd boot
  #      doesn't respawn it from disk)
  # Fails clearly if the entry is missing — caller can decide how to
  # surface that. Only `feishu` adapters are supported in v1; other
  # types skip the FAA-peer step.
  def dispatch("cli:adapters/remove", %{"instance_id" => instance_id})
      when is_binary(instance_id) and instance_id != "" do
    path = Esr.Paths.adapters_yaml()

    case read_adapters_yaml(path, instance_id) do
      {:ok, doc, instance} ->
        type = instance["type"] || "unknown"

        _ = Esr.WorkerSupervisor.terminate_adapter(type, instance_id)

        if type == "feishu" do
          _ = Esr.Scope.Admin.terminate_feishu_app_adapter(instance_id)
        end

        new_doc = update_in(doc, ["instances"], &Map.delete(&1 || %{}, instance_id))
        :ok = Esr.Yaml.Writer.write(path, new_doc)

        %{"data" => %{"ok" => true, "instance_id" => instance_id, "type" => type}}

      {:error, :not_found} ->
        %{"data" => %{"ok" => false, "error" => "unknown_instance: #{instance_id}"}}

      {:error, reason} ->
        %{"data" => %{"ok" => false, "error" => "yaml_read_failed: #{inspect(reason)}"}}
    end
  end

  def dispatch("cli:adapters/remove", _payload) do
    %{"data" => %{"ok" => false, "error" => "missing instance_id"}}
  end

  # PR-O 2026-04-28: rename an adapter instance from `old` to `new`.
  # Same blast radius as remove + add: terminate the running peer +
  # subprocess under the old name, rewrite adapters.yaml with the new
  # key, then refresh to spawn under the new name. New name is
  # validated server-side too so a misconfigured CLI can't smuggle
  # bad bytes into the runtime.
  def dispatch("cli:adapters/rename", %{"old_instance_id" => old, "new_instance_id" => new})
      when is_binary(old) and old != "" and is_binary(new) and new != "" do
    cond do
      not Regex.match?(~r/^[A-Za-z][A-Za-z0-9_-]{0,62}$/, new) ->
        %{"data" => %{"ok" => false, "error" => "invalid_new_name: #{new}"}}

      old == new ->
        %{"data" => %{"ok" => false, "error" => "old_and_new_match"}}

      true ->
        path = Esr.Paths.adapters_yaml()

        case read_adapters_yaml(path, old) do
          {:ok, doc, instance} ->
            instances = doc["instances"] || %{}

            if Map.has_key?(instances, new) do
              %{"data" => %{"ok" => false, "error" => "new_name_already_exists: #{new}"}}
            else
              type = instance["type"] || "unknown"

              # 1. Terminate old running children (if any).
              _ = Esr.WorkerSupervisor.terminate_adapter(type, old)

              if type == "feishu" do
                _ = Esr.Scope.Admin.terminate_feishu_app_adapter(old)
              end

              # 2. Rewrite adapters.yaml with the new key.
              new_instances =
                instances
                |> Map.delete(old)
                |> Map.put(new, instance)

              new_doc = Map.put(doc, "instances", new_instances)
              :ok = Esr.Yaml.Writer.write(path, new_doc)

              # 3. Refresh to spawn under the new name.
              _ = Esr.Application.restore_adapters_from_disk(Esr.Paths.esrd_home())
              _ = Esr.Plugins.Feishu.Bootstrap.bootstrap()

              %{"data" => %{
                "ok" => true,
                "old_instance_id" => old,
                "new_instance_id" => new,
                "type" => type
              }}
            end

          {:error, :not_found} ->
            %{"data" => %{"ok" => false, "error" => "unknown_instance: #{old}"}}

          {:error, reason} ->
            %{"data" => %{"ok" => false, "error" => "yaml_read_failed: #{inspect(reason)}"}}
        end
    end
  end

  def dispatch("cli:adapters/rename", _payload) do
    %{"data" => %{"ok" => false, "error" => "missing old_instance_id and/or new_instance_id"}}
  end

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

  # PR-L 2026-04-28: helper for cli:adapters/remove — reads adapters.yaml
  # and returns either {:ok, doc, instance_map} when the named instance
  # exists, {:error, :not_found} when it doesn't, or {:error, reason}
  # when the file is missing/malformed. Pure I/O wrapper; no side effects.
  defp read_adapters_yaml(path, instance_id) do
    cond do
      not File.exists?(path) ->
        {:error, :not_found}

      true ->
        case YamlElixir.read_from_file(path) do
          {:ok, doc} when is_map(doc) ->
            instances = doc["instances"] || %{}

            case Map.get(instances, instance_id) do
              nil -> {:error, :not_found}
              instance when is_map(instance) -> {:ok, doc, instance}
            end

          {:ok, _} ->
            {:error, :malformed_yaml}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # PR-F 2026-04-28: workspace-for-LLM filter. Allowlist top-level
  # fields (operational config + secrets stay out); pass `metadata` as
  # a free-form sub-tree so operators can add business-topology
  # context without code changes. chat-level filter via Map.take.
  @ws_allowed_fields ~w(name role chats neighbors_declared metadata)
  @chat_allowed_fields ~w(chat_id app_id kind name metadata)

  defp filter_workspace_for_llm(%Esr.Resource.Workspace.Registry.Workspace{} = ws) do
    %{
      "name" => ws.name,
      "role" => ws.role || "dev",
      "chats" => Enum.map(ws.chats || [], &filter_chat_for_llm/1),
      "neighbors_declared" => ws.neighbors || [],
      "metadata" => ws.metadata || %{}
    }
    |> Map.take(@ws_allowed_fields)
  end

  defp filter_chat_for_llm(chat) when is_map(chat),
    do: Map.take(chat, @chat_allowed_fields)

  defp filter_chat_for_llm(_), do: %{}

  # PR-F 2026-04-28: parse `Workspace.neighbors` (list of `<type>:<id>`
  # strings) for `workspace:<name>` entries; look up each via
  # Workspaces.Registry. Non-workspace neighbour types (chat:, user:,
  # adapter:) stay as raw strings in `neighbors_declared` for the LLM
  # to interpret — only workspace-typed entries get expanded into
  # full `neighbor_workspaces` metadata. See spec §4.3.
  defp resolve_neighbour_workspaces(%Esr.Resource.Workspace.Registry.Workspace{neighbors: neighbours}) do
    neighbours
    |> Enum.flat_map(fn entry ->
      case String.split(entry || "", ":", parts: 2) do
        ["workspace", name] ->
          case Esr.Resource.Workspace.Registry.get(name) do
            {:ok, ws} -> [ws]
            :error -> []
          end

        _ ->
          []
      end
    end)
  end

  @spec serialise_telemetry_event(TelemetryEvent.t()) :: map()
  defp serialise_telemetry_event(%TelemetryEvent{} = event) do
    %{
      "ts_unix_ms" => event.ts_unix_ms,
      "event" => Enum.map(event.event, &to_string/1),
      "measurements" => stringify_keys(event.measurements),
      "metadata" => stringify_keys(event.metadata)
    }
  end

  @spec stringify_keys(map()) :: map()
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {stringify_key(k), v} end)
  end

  # Task H — read dotted path from a nested map, tolerating atom or
  # string keys at any level.
  defp get_in_nested(map, [key]) when is_map(map) do
    atomic =
      try do
        String.to_existing_atom(key)
      rescue
        ArgumentError -> nil
      end

    Map.get(map, key) || (atomic && Map.get(map, atomic))
  end

  defp get_in_nested(map, [key | rest]) when is_map(map) do
    atomic =
      try do
        String.to_existing_atom(key)
      rescue
        ArgumentError -> nil
      end

    case Map.get(map, key) || (atomic && Map.get(map, atomic)) do
      nil -> nil
      nested when is_map(nested) -> get_in_nested(nested, rest)
      _ -> nil
    end
  end

  defp get_in_nested(_, _), do: nil

  @spec stringify_key(term()) :: String.t()
  defp stringify_key(k) when is_binary(k), do: k
  defp stringify_key(k), do: to_string(k)

  defp phoenix_port do
    case EsrWeb.Endpoint.config(:http) do
      opts when is_list(opts) -> Keyword.get(opts, :port, 4001)
      _ -> 4001
    end
  end

  defp actor_id_strip_prefix(actor_id) do
    case String.split(actor_id, ":", parts: 2) do
      [_prefix, suffix] -> suffix
      _ -> actor_id
    end
  end
end
