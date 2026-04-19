defmodule Esr.Topology.Instantiator do
  @moduledoc """
  Topology instantiation pipeline (PRD 01 F13).

  ``instantiate/2`` takes a compiled artifact map (produced by the
  Python EDSL's ``compile_topology`` / ``compile_to_yaml`` — see
  PRD 02 F13/F14) and a params map, then:

   1. Validates every declared param is present.
   2. Substitutes ``{{param}}`` in string-valued node fields (id,
      adapter, init_directive args).
   3. Rejects cyclic ``depends_on`` via Kahn's algorithm.
   4. Spawns a PeerServer per node via ``Esr.PeerSupervisor.start_peer``
      in topological order.
   5. Binds each node's adapter in ``Esr.AdapterHub.Registry``.
   6. Registers the instantiation in ``Esr.Topology.Registry``.

  Idempotent: if ``(name, params)`` is already registered, returns
  the existing handle without re-spawning.

  F13b init_directive dispatch is deferred to the next commit.
  """

  alias Esr.AdapterHub.Registry, as: HubRegistry
  alias Esr.PeerSupervisor
  alias Esr.Topology.Registry, as: TopoRegistry

  @type artifact :: %{
          required(String.t()) => term()
        }

  @default_init_directive_timeout 30_000

  @spec instantiate(artifact(), map(), keyword()) ::
          {:ok, TopoRegistry.Handle.t()}
          | {:error, {:missing_params, [String.t()]}}
          | {:error, :cycle_in_depends_on}
          | {:error, {:init_directive_failed, String.t(), term()}}
          | {:error, term()}
  def instantiate(artifact, params, opts \\ [])
      when is_map(artifact) and is_map(params) and is_list(opts) do
    name = Map.get(artifact, "name", "")

    case TopoRegistry.lookup(name, params) do
      {:ok, existing} ->
        {:ok, existing}

      :error ->
        do_instantiate(artifact, params, name, opts)
    end
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp do_instantiate(artifact, params, name, opts) do
    with :ok <- check_params(artifact, params),
         nodes <- substitute_all(Map.get(artifact, "nodes", []), params),
         {:ok, ordered_ids} <- toposort(nodes),
         {:ok, peer_ids} <- spawn_in_order(nodes, ordered_ids, opts) do
      {:ok, handle} = TopoRegistry.register(name, params, peer_ids)

      :telemetry.execute([:esr, :topology, :instantiated], %{}, %{
        name: name,
        params: params,
        peer_ids: peer_ids
      })

      {:ok, handle}
    end
  end

  # --- Param validation ---------------------------------------------

  defp check_params(artifact, params) do
    required = Map.get(artifact, "params", []) |> Enum.map(&to_string/1)
    supplied = params |> Map.keys() |> Enum.map(&to_string/1) |> MapSet.new()

    missing = Enum.reject(required, &MapSet.member?(supplied, &1))

    if missing == [] do
      :ok
    else
      {:error, {:missing_params, missing}}
    end
  end

  # --- Template substitution ----------------------------------------

  defp substitute_all(nodes, params) do
    Enum.map(nodes, fn node -> substitute_node(node, params) end)
  end

  defp substitute_node(node, params) do
    %{
      "id" => substitute_string(Map.get(node, "id", ""), params),
      "actor_type" => Map.get(node, "actor_type", ""),
      "handler" => Map.get(node, "handler", ""),
      "adapter" =>
        case Map.get(node, "adapter") do
          nil -> nil
          s -> substitute_string(to_string(s), params)
        end,
      "depends_on" =>
        Enum.map(Map.get(node, "depends_on", []), &substitute_string(&1, params)),
      "params" => substitute_map(Map.get(node, "params") || %{}, params),
      "init_directive" => substitute_map(Map.get(node, "init_directive"), params)
    }
  end

  defp substitute_string(str, params) when is_binary(str) do
    Regex.replace(~r/\{\{(\w+)\}\}/, str, fn _whole, name ->
      case Map.fetch(params, name) do
        {:ok, v} ->
          to_string(v)

        :error ->
          # AGENTS.md forbids String.to_atom on user-sourced data
          # (atom-table DoS); refuse silently-substituting nothing.
          raise ArgumentError,
                "missing template param: #{inspect(name)} (got: #{inspect(Map.keys(params))})"
      end
    end)
  end

  defp substitute_string(other, _params), do: other

  defp substitute_map(nil, _params), do: nil

  defp substitute_map(map, params) when is_map(map) do
    for {k, v} <- map, into: %{} do
      {k, substitute_value(v, params)}
    end
  end

  defp substitute_value(v, params) when is_binary(v), do: substitute_string(v, params)
  defp substitute_value(v, params) when is_map(v), do: substitute_map(v, params)
  defp substitute_value(v, _params), do: v

  # --- Topological sort (Kahn) --------------------------------------

  defp toposort(nodes) do
    by_id = Map.new(nodes, &{&1["id"], &1})
    base_indeg = Map.new(by_id, fn {id, _} -> {id, 0} end)
    indeg = Enum.reduce(nodes, base_indeg, &count_indegrees/2)
    edges = Enum.reduce(nodes, %{}, &collect_edges/2)
    ready = for {id, 0} <- indeg, do: id
    kahn(ready, indeg, edges, [], map_size(by_id))
  end

  defp count_indegrees(node, acc) do
    Enum.reduce(node["depends_on"] || [], acc, fn _dep, inner ->
      Map.update(inner, node["id"], 1, &(&1 + 1))
    end)
  end

  defp collect_edges(node, acc) do
    Enum.reduce(node["depends_on"] || [], acc, fn dep, inner ->
      Map.update(inner, dep, [node["id"]], &[node["id"] | &1])
    end)
  end

  defp kahn([], _indeg, _edges, acc, expected) do
    if length(acc) == expected do
      {:ok, Enum.reverse(acc)}
    else
      {:error, :cycle_in_depends_on}
    end
  end

  defp kahn([id | rest], indeg, edges, acc, expected) do
    dependents = Map.get(edges, id, [])

    {next_ready, new_indeg} =
      Enum.reduce(dependents, {rest, indeg}, fn d, {r, idx} ->
        new = Map.update!(idx, d, &(&1 - 1))
        if Map.get(new, d) == 0, do: {r ++ [d], new}, else: {r, new}
      end)

    kahn(next_ready, new_indeg, edges, [id | acc], expected)
  end

  # --- Spawning + binding + init_directive (F13b) -------------------

  defp spawn_in_order(nodes, ordered_ids, opts) do
    by_id = Map.new(nodes, &{&1["id"], &1})
    timeout = Keyword.get(opts, :init_directive_timeout, @default_init_directive_timeout)
    spawn_loop(ordered_ids, by_id, timeout, [])
  end

  defp spawn_loop([], _by_id, _timeout, acc), do: {:ok, Enum.reverse(acc)}

  defp spawn_loop([id | rest], by_id, timeout, acc) do
    node = Map.fetch!(by_id, id)
    {:ok, _pid} = start_peer(node)
    bind_adapter(node)
    # 8f: ensure the Python counterparts are running. Idempotent — any
    # worker already pre-spawned by fixtures (scenario setup) or
    # previously by this supervisor is reused via its pidfile.
    ensure_python_workers(node)

    case issue_init_directive(node, timeout) do
      :ok ->
        spawn_loop(rest, by_id, timeout, [id | acc])

      {:error, reason} ->
        rollback_spawned([id | acc], by_id)
        {:error, {:init_directive_failed, id, reason}}
    end
  end

  defp issue_init_directive(%{"init_directive" => nil}, _timeout), do: :ok

  defp issue_init_directive(%{"init_directive" => init, "id" => node_id, "adapter" => adapter}, timeout)
       when is_map(init) and is_binary(adapter) do
    id = "d-init-" <> Integer.to_string(System.unique_integer([:positive]))
    topic = "adapter:" <> adapter <> "/" <> node_id
    reply_topic = "directive_ack:" <> id

    :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, reply_topic)

    envelope = %{
      "kind" => "directive",
      "id" => id,
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "type" => "directive",
      "source" => "esr://localhost/actor/" <> node_id,
      "payload" => %{
        "adapter" => adapter,
        "action" => init["action"],
        "args" => Map.get(init, "args", %{})
      }
    }

    # Broadcast under the unified "envelope" event shape the Python
    # adapter_runner filters on (event == "envelope", payload.kind
    # == "directive"). The envelope carries its own kind for dispatch.
    EsrWeb.Endpoint.broadcast(topic, "envelope", envelope)

    try do
      receive do
        {:directive_ack, %{"id" => ^id, "payload" => %{"ok" => true}}} ->
          :ok

        {:directive_ack, %{"id" => ^id, "payload" => payload}} ->
          {:error, payload}
      after
        timeout -> {:error, :timeout}
      end
    after
      Phoenix.PubSub.unsubscribe(EsrWeb.PubSub, reply_topic)
    end
  end

  defp issue_init_directive(_node, _timeout), do: :ok

  # Terminate the spawned PeerServers AND synchronously unbind their
  # adapters. The DOWN handler in HubRegistry cleans up bindings async
  # on pid exit, but an immediate instantiate retry could observe stale
  # bindings in the tiny window between termination and DOWN delivery.
  defp rollback_spawned(ids, by_id) do
    Enum.each(ids, fn id ->
      Esr.PeerSupervisor.stop_peer(id)

      case Map.get(by_id, id) do
        %{"adapter" => adapter, "id" => node_id} when is_binary(adapter) ->
          HubRegistry.unbind("adapter:#{adapter}/#{node_id}")

        _ ->
          :ok
      end
    end)
  end

  defp start_peer(node) do
    PeerSupervisor.start_peer(
      actor_id: node["id"],
      actor_type: node["actor_type"],
      handler_module: handler_module_name(node["handler"])
    )
  end

  # Handler refs in a compiled topology are "<module>.<entry>" —
  # HandlerRouter.call takes just the module.
  defp handler_module_name(handler) when is_binary(handler) do
    handler |> String.split(".", parts: 2) |> hd()
  end

  defp bind_adapter(%{"adapter" => nil}), do: :ok

  defp bind_adapter(%{"adapter" => adapter, "id" => id}) when is_binary(adapter) do
    HubRegistry.bind("adapter:#{adapter}/#{id}", id)
  end

  defp bind_adapter(_), do: :ok

  # Launch (or reuse) the Python adapter_runner / handler_worker
  # subprocesses a node needs. WorkerSupervisor is idempotent — already-
  # running workers (whether tracked or externally pre-spawned) are
  # reused. Config for the adapter instance is loaded from
  # ``~/.esrd/<instance>/adapters.yaml`` when available; absent-file
  # falls back to `{}` so at minimum the adapter_runner can attempt
  # to load the adapter factory.
  defp ensure_python_workers(%{"handler" => handler} = node)
       when is_binary(handler) and handler != "" do
    handler_module = handler |> String.split(".", parts: 2) |> hd()
    worker_id = derive_worker_id(node["id"] || "")
    handler_url = handler_hub_url()

    _ = Esr.WorkerSupervisor.ensure_handler(handler_module, worker_id, handler_url)

    case node do
      %{"adapter" => adapter, "id" => id}
      when is_binary(adapter) and adapter != "" and is_binary(id) ->
        config = load_adapter_config(adapter)
        _ = Esr.WorkerSupervisor.ensure_adapter(adapter, id, config, adapter_hub_url())

      _ ->
        :ok
    end

    :ok
  end

  defp ensure_python_workers(_), do: :ok

  # Worker ids are short, stable per-actor slugs. Collisions across
  # actor types within one topology are impossible because node ids are
  # unique, so we strip the prefix and reuse the suffix.
  defp derive_worker_id(actor_id) do
    case String.split(actor_id, ":", parts: 2) do
      [_prefix, suffix] -> "w-" <> suffix
      _ -> "w-" <> actor_id
    end
  end

  defp handler_hub_url do
    "ws://127.0.0.1:" <>
      Integer.to_string(phoenix_port()) <>
      "/handler_hub/socket/websocket?vsn=2.0.0"
  end

  defp adapter_hub_url do
    "ws://127.0.0.1:" <>
      Integer.to_string(phoenix_port()) <>
      "/adapter_hub/socket/websocket?vsn=2.0.0"
  end

  defp phoenix_port do
    # EsrWeb.Endpoint is configured with http: [port: 4001] in dev/prod;
    # tests may override. Read the live value.
    case EsrWeb.Endpoint.config(:http) do
      opts when is_list(opts) -> Keyword.get(opts, :port, 4001)
      _ -> 4001
    end
  end

  defp load_adapter_config(adapter_name) do
    # Scan every ~/.esrd/*/adapters.yaml — esrd instance layout has the
    # config file next to each esrd's pidfile. The first match wins;
    # for our live + scenario instances there is never more than one
    # instance registered per adapter.
    home = System.user_home!()
    base = Path.join(home, ".esrd")

    case File.ls(base) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join([base, &1, "adapters.yaml"]))
        |> Enum.filter(&File.regular?/1)
        |> Enum.find_value(%{}, fn file -> read_adapter_entry(file, adapter_name) end)

      _ ->
        %{}
    end
  end

  defp read_adapter_entry(file, adapter_name) do
    with {:ok, contents} <- File.read(file),
         {:ok, parsed} <- YamlElixir.read_from_string(contents),
         %{"instances" => instances} when is_map(instances) <- parsed do
      Enum.find_value(instances, nil, fn
        {_name, %{"type" => ^adapter_name, "config" => cfg}} when is_map(cfg) -> cfg
        _ -> nil
      end)
    else
      _ -> nil
    end
  end
end
