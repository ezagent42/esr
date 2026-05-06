defmodule Esr.Resource.Workspace.Describe do
  @moduledoc """
  Single source of truth for the security-filtered workspace data
  shape returned by the `describe_topology` MCP tool (cc plugin) and
  the `/workspace describe` slash command (operators).

  ## Security boundary

  This is the **only** function that decides what
  `describe_topology` exposes to the LLM (or to a slash-callable
  operator). It is an explicit allowlist — adding a new field to
  `%Workspace{}` does NOT auto-expose it.

  **Exposed fields (current_workspace):**
    - `name`              — workspace name
    - `role`              — from settings._legacy.role
    - `chats`             — allowlisted sub-map (see filter_chat/1)
    - `neighbors_declared`— union of struct neighbors + topology.yaml neighbors
    - `metadata`          — union of struct metadata + topology.yaml metadata
    - `description`       — NEW (Phase 7.1): only present when topology.yaml has it
    - `topology_overlay`  — NEW (Phase 7.1): boolean, true when overlay was applied

  **Excluded by design:**
    - `owner` (esr-username — sensitive once paired with `users.yaml`'s
      feishu_ids; describe_topology is principal-agnostic on purpose)
    - `start_cmd` (operator config; could leak shell paths / args)
    - `env` (workspace env block — may carry secrets)

  The chats sub-map uses its own allowlist for the same reason. Never
  expose `users.yaml` data here — feishu open_ids / esr-username
  pairings are out-of-band identity material.

  ## Topology overlay (Phase 7.1)

  When `folders[0].path/.esr/topology.yaml` is present and parses to
  a map, the following fields are merged into the response:
    - `description` (string) — NEW exposed key, only present when non-empty
    - `metadata` (map) — UNION with struct metadata; topology.yaml wins on conflicts
    - `neighbors` (list) — UNION with neighbors_declared; deduplicated

  If topology.yaml is absent or fails to parse, the overlay is silently
  skipped (topology_overlay=false). No error is logged at LLM level;
  the file is entirely optional.

  Default-deny: if you need a new field, add it AND a regression test
  in `runtime/test/esr/entity_server_describe_topology_test.exs`.
  """

  alias Esr.Resource.Workspace.{NameIndex, Registry, Struct}

  @name_index_table :esr_workspace_name_index

  @type ok_data :: %{required(String.t()) => any()}
  @type result :: {:ok, ok_data()} | {:error, :unknown_workspace | :missing_workspace_name}

  @spec describe(String.t() | nil) :: result()
  def describe(ws_name) when is_binary(ws_name) and ws_name != "" do
    case lookup_struct(ws_name) do
      {:ok, %Struct{} = ws} ->
        overlay = read_topology_overlay(ws)
        neighbours = resolve_neighbour_workspaces(ws, overlay)

        {:ok,
         %{
           "current_workspace" => filter_workspace(ws, overlay),
           "neighbor_workspaces" => Enum.map(neighbours, &filter_workspace(&1, %{}))
         }}

      :not_found ->
        {:error, :unknown_workspace}
    end
  end

  def describe(_), do: {:error, :missing_workspace_name}

  ## Internals -------------------------------------------------------------

  # Try NameIndex → UUID → new Struct. Falls through to :not_found when
  # NameIndex ETS table is not started (ArgumentError) or name unknown.
  defp lookup_struct(name) do
    case NameIndex.id_for_name(@name_index_table, name) do
      {:ok, id} ->
        case Registry.get_by_id(id) do
          {:ok, ws} -> {:ok, ws}
          :not_found -> :not_found
        end

      :not_found ->
        :not_found
    end
  rescue
    # NameIndex ETS tables not created (admin-CLI or test without Registry started)
    ArgumentError -> :not_found
  end

  defp read_topology_overlay(%Struct{folders: [first | _]}) do
    path = Map.get(first, :path) || Map.get(first, "path")

    if is_binary(path) and path != "" do
      yaml_path = Path.join([path, ".esr", "topology.yaml"])

      if File.exists?(yaml_path) do
        case YamlElixir.read_from_file(yaml_path) do
          {:ok, %{} = data} -> data
          _ -> %{}
        end
      else
        %{}
      end
    else
      %{}
    end
  end

  defp read_topology_overlay(_), do: %{}

  # PR-21z + Phase 7.1: allowlist-based filter.
  # topology.yaml overlay contributes ONLY to description (new),
  # metadata (union), and neighbors_declared (union).
  # Any other field must NOT be added without a security regression test.
  defp filter_workspace(%Struct{} = ws, overlay) do
    base_neighbors = legacy_neighbors(ws)
    base_metadata = legacy_metadata(ws)

    overlay_neighbors = Map.get(overlay, "neighbors") |> List.wrap()
    overlay_metadata = Map.get(overlay, "metadata") || %{}

    merged_neighbors = (base_neighbors ++ overlay_neighbors) |> Enum.uniq()
    merged_metadata = Map.merge(base_metadata, overlay_metadata)
    desc = Map.get(overlay, "description")

    base = %{
      "name" => ws.name,
      "role" => Map.get(ws.settings, "_legacy.role", "dev"),
      "chats" => Enum.map(ws.chats || [], &filter_chat/1),
      "neighbors_declared" => merged_neighbors,
      "metadata" => merged_metadata,
      "topology_overlay" => map_size(overlay) > 0
    }

    if is_binary(desc) and desc != "", do: Map.put(base, "description", desc), else: base
  end

  defp filter_chat(chat) when is_map(chat) do
    chat
    |> normalise_chat_to_string_keys()
    |> Map.take(["chat_id", "app_id", "kind", "name", "metadata"])
  end

  defp filter_chat(_), do: %{}

  defp normalise_chat_to_string_keys(%{chat_id: c, app_id: a} = m) do
    %{
      "chat_id" => c,
      "app_id" => a,
      "kind" => Map.get(m, :kind, "dm"),
      "name" => Map.get(m, :name, ""),
      "metadata" => Map.get(m, :metadata, %{})
    }
  end

  defp normalise_chat_to_string_keys(m), do: m

  defp legacy_neighbors(%Struct{settings: settings}) do
    Map.get(settings, "_legacy.neighbors", []) |> List.wrap()
  end

  defp legacy_metadata(%Struct{settings: settings}) do
    case Map.get(settings, "_legacy.metadata") do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  # Resolve neighbour workspaces by name from both legacy neighbors
  # and overlay-merged neighbors.
  defp resolve_neighbour_workspaces(%Struct{} = ws, overlay) do
    legacy = legacy_neighbors(ws)
    overlay_n = Map.get(overlay, "neighbors") |> List.wrap()

    (legacy ++ overlay_n)
    |> Enum.uniq()
    |> Enum.flat_map(fn entry ->
      case String.split(entry || "", ":", parts: 2) do
        ["workspace", n] ->
          case lookup_struct(n) do
            {:ok, %Struct{} = neighbour} -> [neighbour]
            _ -> []
          end

        _ ->
          []
      end
    end)
  end
end
