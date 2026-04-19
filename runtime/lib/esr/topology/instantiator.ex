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

    case issue_init_directive(node, timeout) do
      :ok ->
        spawn_loop(rest, by_id, timeout, [id | acc])

      {:error, reason} ->
        rollback_spawned([id | acc])
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

    EsrWeb.Endpoint.broadcast(topic, "directive", envelope)

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

  defp rollback_spawned(ids) do
    Enum.each(ids, &Esr.PeerSupervisor.stop_peer/1)
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
end
