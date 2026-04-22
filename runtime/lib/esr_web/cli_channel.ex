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

  alias Esr.DeadLetter.Entry, as: DeadLetterEntry
  alias Esr.Telemetry.Buffer
  alias Esr.Telemetry.Buffer.Event, as: TelemetryEvent
  alias Esr.Topology.Instantiator

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
      Esr.PeerRegistry.list_all()
      |> Enum.map(fn {actor_id, pid} ->
        %{"actor_id" => actor_id, "pid" => inspect(pid)}
      end)

    %{"data" => data}
  end

  def dispatch("cli:actors/tree", _payload) do
    topologies =
      Esr.Topology.Registry.list_all()
      |> Enum.map(fn h ->
        %{
          "name" => h.name,
          "params" => stringify_keys(h.params),
          "peer_ids" => h.peer_ids
        }
      end)

    %{"data" => %{"topologies" => topologies}}
  end

  def dispatch("cli:actors/inspect", %{"arg" => actor_id}) when is_binary(actor_id) do
    case Esr.PeerRegistry.lookup(actor_id) do
      {:ok, _pid} ->
        snap = Esr.PeerServer.describe(actor_id)

        data = %{
          "actor_id" => snap.actor_id,
          "actor_type" => snap.actor_type,
          "handler_module" => snap.handler_module,
          "paused" => snap.paused,
          "state" => stringify_keys(snap.state)
        }

        # Augment with chat_ids from SessionSocketRegistry if this actor is a
        # cc_proxy / feishu_thread_proxy etc tracked there.
        session_ctx =
          case Esr.SessionSocketRegistry.lookup(actor_id_strip_prefix(snap.actor_id)) do
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

  def dispatch("cli:run/" <> name, payload) when is_binary(name) do
    artifact = Map.get(payload, "artifact") || %{"name" => name}
    params = Map.get(payload, "params") || %{}

    # Register the artifact so future InvokeCommand actions (fired by
    # handlers via e.g. /new-thread) can look it up. ETS is shared
    # across all PeerServers; one put_artifact per distinct name.
    :ok = Esr.Topology.Registry.put_artifact(name, artifact)

    case Instantiator.instantiate(artifact, params) do
      {:ok, handle} ->
        %{
          "data" => %{
            "name" => handle.name,
            "params" => handle.params,
            "peer_ids" => handle.peer_ids
          }
        }

      {:error, reason} ->
        %{
          "data" => %{
            "error" => instantiate_error_message(reason),
            "name" => name,
            "params" => params,
            "peer_ids" => []
          }
        }
    end
  end

  def dispatch("cli:stop/" <> name, payload) when is_binary(name) do
    params = Map.get(payload, "params") || %{}

    case Esr.Topology.Registry.lookup(name, params) do
      {:ok, handle} ->
        :ok = Esr.Topology.Registry.deactivate(handle)

        %{
          "data" => %{
            "name" => name,
            "params" => params,
            "stopped_peer_ids" => handle.peer_ids
          }
        }

      :error ->
        %{
          "data" => %{
            "error" => "instantiation not found",
            "name" => name,
            "params" => params,
            "stopped_peer_ids" => []
          }
        }
    end
  end

  def dispatch("cli:drain", _payload) do
    handles = Esr.Topology.Registry.list_all()

    peer_ids =
      handles
      |> Enum.flat_map(& &1.peer_ids)

    Enum.each(handles, &Esr.Topology.Registry.deactivate/1)

    %{
      "data" => %{
        "drained" => Enum.map(handles, fn h ->
          %{"name" => h.name, "params" => stringify_keys(h.params), "peer_ids" => h.peer_ids}
        end),
        "stopped_peer_ids" => peer_ids,
        "timeouts" => []
      }
    }
  end

  def dispatch("cli:debug/pause", %{"actor_id" => actor_id}) when is_binary(actor_id) do
    debug_toggle(actor_id, :pause)
  end

  def dispatch("cli:debug/resume", %{"actor_id" => actor_id}) when is_binary(actor_id) do
    debug_toggle(actor_id, :resume)
  end

  def dispatch("cli:debug/" <> _op, _payload) do
    %{"data" => %{"error" => "missing 'actor_id' in payload"}}
  end

  def dispatch("cli:deadletter/list", _payload) do
    data =
      Esr.DeadLetter
      |> Esr.DeadLetter.list()
      |> Enum.map(&serialise_dl_entry/1)

    %{"data" => data}
  end

  def dispatch("cli:deadletter/flush", _payload) do
    flushed = length(Esr.DeadLetter.list(Esr.DeadLetter))
    :ok = Esr.DeadLetter.clear(Esr.DeadLetter)
    %{"data" => %{"flushed" => flushed}}
  end

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

  def dispatch("cli:workspace/register", payload) do
    alias Esr.Workspaces.Registry, as: WorkspacesReg

    name = Map.get(payload, "name")

    if is_binary(name) and name != "" do
      ws = %WorkspacesReg.Workspace{
        name: name,
        cwd: payload["cwd"] || "",
        start_cmd: payload["start_cmd"] || "",
        role: payload["role"] || "dev",
        chats: payload["chats"] || [],
        env: payload["env"] || %{}
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

  @spec instantiate_error_message(term()) :: String.t()
  defp instantiate_error_message({:missing_params, names}) do
    "missing_params: #{Enum.join(names, ", ")}"
  end

  defp instantiate_error_message(:cycle_in_depends_on) do
    "cycle_in_depends_on"
  end

  defp instantiate_error_message({:init_directive_failed, node_id, detail}) do
    "init_directive_failed on #{node_id}: #{inspect(detail)}"
  end

  defp instantiate_error_message(other) do
    "instantiate_failed: #{inspect(other)}"
  end

  @spec debug_toggle(String.t(), :pause | :resume) :: map()
  defp debug_toggle(actor_id, op) do
    case Esr.PeerRegistry.lookup(actor_id) do
      {:ok, _pid} ->
        :ok =
          case op do
            :pause -> Esr.PeerServer.pause(actor_id)
            :resume -> Esr.PeerServer.resume(actor_id)
          end

        snap = Esr.PeerServer.describe(actor_id)
        %{"data" => %{"actor_id" => actor_id, "paused" => snap.paused}}

      :error ->
        %{"data" => %{"error" => "actor not found", "actor_id" => actor_id}}
    end
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

  @spec stringify_key(term()) :: String.t()
  defp stringify_key(k) when is_binary(k), do: k
  defp stringify_key(k), do: to_string(k)

  defp phoenix_port do
    case EsrWeb.Endpoint.config(:http) do
      opts when is_list(opts) -> Keyword.get(opts, :port, 4001)
      _ -> 4001
    end
  end

  @spec serialise_dl_entry(DeadLetterEntry.t()) :: map()
  defp serialise_dl_entry(%DeadLetterEntry{} = entry) do
    %{
      "id" => entry.id,
      "ts_unix_ms" => entry.ts_unix_ms,
      "reason" => to_string(entry.reason),
      "target" => entry.target,
      "source" => entry.source,
      "msg" => inspect(entry.msg),
      "metadata" => entry.metadata
    }
  end

  defp actor_id_strip_prefix(actor_id) do
    case String.split(actor_id, ":", parts: 2) do
      [_prefix, suffix] -> suffix
      _ -> actor_id
    end
  end
end
