defmodule Esr.Commands.Workspace.Info do
  @moduledoc """
  `Esr.Commands.Workspace.Info` — display the configuration of
  one workspace (PR-21j). Dispatcher kind `workspace_info`.

  ## Args

      args: %{"workspace" => "esr-dev"}

  or the alias:

      args: %{"name" => "esr-dev"}

  When `workspace` (or `name`) is omitted but the slash command has a chat
  context, `SlashHandler` resolves the chat to a workspace and fills
  it in. Direct admin-CLI submits must specify it.

  ## Result shape

      {:ok, %{
        "name"      => "esr-dev",
        "id"        => "<uuid>",
        "owner"     => "linyilun",
        "agent"     => "cc",
        "folders"   => [%{"path" => "...", "name" => "..."}],
        "settings"  => %{},                    # _legacy.* keys filtered out
        "env"       => %{},
        "chats"     => [%{"chat_id" => ..., "app_id" => ..., "kind" => ...}],
        "transient" => false,
        "location"  => "esr:<dir>" | "repo:<path>",
        "role"      => "dev",                  # from settings["_legacy.role"]
        "metadata"  => %{},                    # from settings["_legacy.metadata"]
        "topology"  => %{...} | nil            # <folders[0].path>/.esr/topology.yaml
      }}

  Read-only — touches `Esr.Resource.Workspace.Registry` and
  `Esr.Resource.Workspace.NameIndex` only.
  """

  @behaviour Esr.Role.Control

  require Logger

  alias Esr.Resource.Workspace.NameIndex
  alias Esr.Resource.Workspace.Registry

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()

  # Accept args.workspace (existing route)
  def execute(%{"args" => %{"workspace" => ws}}) when is_binary(ws) and ws != "",
    do: do_info(ws)

  # Accept args.name alias (new route, Phase 4.11)
  def execute(%{"args" => %{"name" => ws}}) when is_binary(ws) and ws != "",
    do: do_info(ws)

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "workspace_info requires args.workspace (non-empty string)"
     }}
  end

  ## Internals --------------------------------------------------------------

  defp do_info(ws_name) do
    case lookup_struct(ws_name) do
      {:ok, ws} ->
        {:ok, build_result(ws)}

      {:legacy, w} ->
        # NameIndex not running (admin-CLI without full app boot); fall back
        # to legacy struct shape for compat.
        {:ok, build_legacy_result(w)}

      :not_found ->
        {:error, %{"type" => "unknown_workspace", "workspace" => ws_name}}
    end
  end

  # Try NameIndex → UUID → new Struct. Falls back to legacy table when
  # NameIndex ETS table is not started (ArgumentError from :ets.lookup).
  defp lookup_struct(ws_name) do
    id =
      case NameIndex.id_for_name(:esr_workspace_name_index, ws_name) do
        {:ok, id} -> id
        :not_found -> nil
      end

    if id do
      case Registry.get_by_id(id) do
        {:ok, ws} -> {:ok, ws}
        :not_found -> :not_found
      end
    else
      :not_found
    end
  rescue
    # NameIndex ETS tables not created (admin-CLI or test without Registry started)
    ArgumentError -> lookup_legacy(ws_name)
  end

  defp lookup_legacy(ws_name) do
    case Registry.get(ws_name) do
      {:ok, w} -> {:legacy, w}
      :error -> :not_found
    end
  end

  defp build_result(ws) do
    settings = ws.settings || %{}

    # Filter out _legacy.* keys for user-facing settings
    clean_settings =
      settings
      |> Enum.reject(fn {k, _v} -> String.starts_with?(k, "_legacy.") end)
      |> Map.new()

    # Surface legacy-stashed fields
    role = Map.get(settings, "_legacy.role", "dev")
    metadata = Map.get(settings, "_legacy.metadata", %{})

    # Serialise chats to string-keyed maps
    chats =
      Enum.map(ws.chats || [], fn c ->
        %{
          "chat_id" => Map.get(c, :chat_id) || Map.get(c, "chat_id"),
          "app_id" => Map.get(c, :app_id) || Map.get(c, "app_id"),
          "kind" => Map.get(c, :kind) || Map.get(c, "kind") || "dm"
        }
      end)

    # Encode location as a human-readable string
    location =
      case ws.location do
        {:esr_bound, dir} -> "esr:#{dir}"
        {:repo_bound, path} -> "repo:#{path}"
        _ -> nil
      end

    # Topology overlay: load from <folders[0].path>/.esr/topology.yaml
    topology = load_topology(ws.folders)

    %{
      "name" => ws.name,
      "id" => ws.id,
      "owner" => ws.owner,
      "agent" => ws.agent || "cc",
      "folders" => serialize_folders(ws.folders),
      "settings" => clean_settings,
      "env" => ws.env || %{},
      "chats" => chats,
      "transient" => ws.transient || false,
      "location" => location,
      "role" => role,
      "metadata" => metadata,
      "topology" => topology
    }
  end

  defp build_legacy_result(w) do
    %{
      "name" => w.name,
      "id" => nil,
      "owner" => w.owner,
      "agent" => "cc",
      "folders" => [],
      "settings" => %{},
      "env" => w.env || %{},
      "chats" => w.chats || [],
      "transient" => false,
      "location" => nil,
      "role" => w.role || "dev",
      "metadata" => w.metadata || %{},
      "topology" => nil
    }
  end

  defp serialize_folders(folders) when is_list(folders) do
    Enum.map(folders, fn
      %{path: path, name: name} -> %{"path" => path, "name" => name}
      %{path: path} -> %{"path" => path}
      %{"path" => _} = m -> m
      other -> other
    end)
  end

  defp serialize_folders(_), do: []

  defp load_topology([first | _]) do
    folder_path = Map.get(first, :path) || Map.get(first, "path")

    if is_binary(folder_path) and folder_path != "" do
      topology_path = Path.join([folder_path, ".esr", "topology.yaml"])

      if File.exists?(topology_path) do
        case YamlElixir.read_from_file(topology_path) do
          {:ok, parsed} ->
            parsed

          {:error, reason} ->
            Logger.warning(
              "workspace.info: failed to parse topology.yaml at #{topology_path}: #{inspect(reason)}"
            )

            nil
        end
      else
        nil
      end
    else
      nil
    end
  end

  defp load_topology(_), do: nil
end
