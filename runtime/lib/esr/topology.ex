defmodule Esr.Topology do
  @moduledoc """
  Actor topology lookups for the routing-table reachable_set
  (spec 2026-04-27 actor-topology-routing §4 + §6).

  Given the workspaces.yaml-driven `Esr.Resource.Workspace.Registry`, this
  module exposes:

  - `initial_seed/3` — the URI set a CC peer's `reachable_set` should
    start with: own chat + adapter + symmetric neighbour closure.
  - `neighbour_set/1` — the URI set reachable as neighbours for a
    given workspace, post-symmetric-closure.
  - `symmetric_closure/0` — full closure map (workspace → URI set).

  The closure is symmetric per spec §6.4: declaring
  `workspace:ws_kanban` in `ws_dev`'s `neighbors:` automatically
  makes every chat in `ws_dev` appear in `ws_kanban`'s neighbour set
  too. Asymmetric capabilities live in `capabilities.yaml` and are
  enforced by Lane B at send time — not by the topology graph.

  ## URI shapes used here

  - chat: `esr://<host>/workspaces/<ws>/chats/<chat_id>`
  - user: `esr://<host>/users/<open_id>`
  - adapter: `esr://<host>/adapters/<platform>/<app_id>`

  All built via `Esr.Uri.build_path/2` for shape consistency.
  """

  alias Esr.Resource.Workspace.Registry, as: WS

  # Match the host string used by feishu_app_adapter / runner_core
  # source URI emit so the strings reachable_set learns at runtime
  # match what initial_seed produced. Keeping this hardcoded here
  # mirrors how peer_server.ex / runner_core.py both hardcode
  # "localhost"; future spec change can lift it via config.
  @host "localhost"

  @doc """
  Returns the initial `reachable_set` MapSet for a CC peer.

  - `workspace_name`: the session's workspace (lookup key into the
    neighbour graph).
  - `chat_uri`: the session's own chat URI.
  - `adapter_uri`: optional — the URI of the adapter that delivered
    the bootstrapping inbound; if `nil`, omitted from the seed.
  """
  @spec initial_seed(String.t(), String.t(), String.t() | nil) :: MapSet.t(String.t())
  def initial_seed(workspace_name, chat_uri, adapter_uri \\ nil)
      when is_binary(workspace_name) and is_binary(chat_uri) do
    base =
      [chat_uri | List.wrap(adapter_uri)]
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    MapSet.union(base, neighbour_set(workspace_name))
  end

  @doc """
  Returns the URI set declared as neighbours for `workspace_name`,
  after symmetric closure.

  An empty MapSet is returned for unknown workspaces (no warning —
  the absence is normal during boot before yaml has loaded).
  """
  @spec neighbour_set(String.t()) :: MapSet.t(String.t())
  def neighbour_set(workspace_name) when is_binary(workspace_name) do
    Map.get(symmetric_closure(), workspace_name, MapSet.new())
  end

  @doc """
  Computes the full symmetric-closure map.

  Returns a `%{workspace_name => MapSet.t(uri)}` where each URI set
  contains everything reachable for that workspace through the
  declared `neighbors:` entries plus the implicit reverse edges.
  """
  @spec symmetric_closure() :: %{String.t() => MapSet.t(String.t())}
  def symmetric_closure do
    workspaces = WS.list()
    ws_by_name = Map.new(workspaces, &{&1.name, &1})

    # Direct edges: each workspace's declared `neighbors:` expanded
    # into actor URIs.
    direct_edges =
      for ws <- workspaces,
          entry <- ws.neighbors || [],
          uri <- resolve_neighbour_entry(entry, ws_by_name) do
        {ws.name, uri}
      end

    # Symmetric reverse edges: for every `workspace:<other>` entry in
    # ws_A's neighbours, every chat in ws_A becomes a neighbour for
    # ws_other. (User entries have no implicit reverse — a user actor
    # is not a workspace, so reachability flows in the declared
    # direction only.)
    reverse_edges =
      Enum.flat_map(workspaces, fn ws ->
        Enum.flat_map(ws.neighbors || [], fn entry ->
          case parse_workspace_entry(entry) do
            {:ok, target_ws_name} ->
              if Map.has_key?(ws_by_name, target_ws_name) do
                Enum.map(chats_of(ws), &{target_ws_name, &1})
              else
                []
              end

            :other ->
              []
          end
        end)
      end)

    (direct_edges ++ reverse_edges)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {from, uris} -> {from, MapSet.new(uris)} end)
  end

  @doc """
  Builds the canonical chat URI for a given workspace + chat_id.

  Used by callers that have a `(workspace, chat_id)` and need a URI
  string (e.g. `cc_process` building its session's own chat URI for
  the `<channel>` tag and initial seed).
  """
  @spec chat_uri(String.t(), String.t()) :: String.t()
  def chat_uri(workspace_name, chat_id)
      when is_binary(workspace_name) and is_binary(chat_id) do
    Esr.Uri.build_path(["workspaces", workspace_name, "chats", chat_id], @host)
  end

  @doc """
  Builds the canonical user URI for a feishu open_id.

  PR-21b rekey: looks up the open_id in `Esr.Entity.User.Registry` and uses
  the bound esr-username when available. Falls back to the raw open_id
  with a warning when the id is not yet bound — this preserves
  backwards-compatible reachable_set construction during the rollout
  window. Once every active operator has been bound (`esr user
  bind-feishu …`), the warning path goes silent.
  """
  @spec user_uri(String.t()) :: String.t()
  def user_uri(open_id) when is_binary(open_id) do
    id = resolve_user_id(open_id)
    Esr.Uri.build_path(["users", id], @host)
  end

  defp resolve_user_id(open_id) do
    if Process.whereis(Esr.Entity.User.Registry) do
      case Esr.Entity.User.Registry.lookup_by_feishu_id(open_id) do
        {:ok, username} ->
          username

        :not_found ->
          require Logger

          Logger.warning(
            "topology: feishu open_id #{open_id} has no esr user binding; using raw id in URI. " <>
              "Bind via `esr user bind-feishu <user> #{open_id}` to fix."
          )

          open_id
      end
    else
      # Tests / boot edge-case: Registry not up yet. Fall back without warning.
      open_id
    end
  end

  @doc """
  Builds the canonical adapter URI for a platform + app_id.
  """
  @spec adapter_uri(String.t(), String.t()) :: String.t()
  def adapter_uri(platform, app_id)
      when is_binary(platform) and is_binary(app_id) do
    Esr.Uri.build_path(["adapters", platform, app_id], @host)
  end

  # ------------------------------------------------------------------
  # internals
  # ------------------------------------------------------------------

  # `entry` is one yaml line under `neighbors:` — strict `<type>:<id>`
  # form per spec §6.3. Returns the list of actor URIs the entry
  # expands to (multiple URIs for `workspace:<ws>` since that's a
  # collection; single-element list for chat / user / adapter).
  defp resolve_neighbour_entry(entry, ws_by_name) when is_binary(entry) do
    case String.split(entry, ":", parts: 2) do
      ["workspace", ws_name] ->
        case Map.get(ws_by_name, ws_name) do
          nil -> []
          ws -> chats_of(ws)
        end

      ["chat", chat_id] ->
        # No workspace context in the yaml entry — scan registered
        # workspaces and emit the URI for the first match. If no
        # workspace owns this chat_id, drop with a soft warn.
        case find_chat_workspace(chat_id, ws_by_name) do
          nil ->
            require Logger
            Logger.warning(
              "topology: neighbour entry chat:#{chat_id} matches no workspace's chats; dropped"
            )

            []

          ws_name ->
            [chat_uri(ws_name, chat_id)]
        end

      ["user", open_id] ->
        [user_uri(open_id)]

      ["adapter", rest] ->
        # Accept "platform:app_id" or "platform/app_id"; the spec
        # example uses `adapter:feishu:app_other`. Split on the
        # remaining colon.
        case String.split(rest, ":", parts: 2) do
          [platform, app_id] -> [adapter_uri(platform, app_id)]
          _ -> []
        end

      _ ->
        require Logger
        Logger.warning(
          "topology: malformed neighbour entry #{inspect(entry)}; expected `<type>:<id>`"
        )

        []
    end
  end

  defp resolve_neighbour_entry(_, _), do: []

  defp parse_workspace_entry(entry) when is_binary(entry) do
    case String.split(entry, ":", parts: 2) do
      ["workspace", ws_name] -> {:ok, ws_name}
      _ -> :other
    end
  end

  defp chats_of(%WS.Workspace{name: ws_name, chats: chats}) when is_list(chats) do
    Enum.flat_map(chats, fn
      %{"chat_id" => chat_id} when is_binary(chat_id) -> [chat_uri(ws_name, chat_id)]
      _ -> []
    end)
  end

  defp chats_of(_), do: []

  defp find_chat_workspace(chat_id, ws_by_name) do
    Enum.find_value(ws_by_name, fn {name, ws} ->
      if Enum.any?(ws.chats || [], fn c -> c["chat_id"] == chat_id end), do: name
    end)
  end
end
