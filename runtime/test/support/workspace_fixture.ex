defmodule Esr.Test.WorkspaceFixture do
  @moduledoc """
  M-4 — drop-in replacement for the deleted legacy
  `%Esr.Resource.Workspace.Registry.Workspace{}` struct constructor.

  Tests previously built workspaces like:

      %Esr.Resource.Workspace.Registry.Workspace{
        name: "ws_alpha",
        owner: "linyilun",
        role: "dev",
        start_cmd: "claude",
        chats: [%{"chat_id" => "oc_a", "app_id" => "cli_x", "kind" => "dm"}],
        env: %{},
        metadata: %{"purpose" => "test"}
      }

  After M-4 the legacy struct is gone. Tests now build the canonical
  `%Esr.Resource.Workspace.Struct{}` — but threading an `id`, an `agent`,
  a `folders` list, etc. by hand at every callsite is noisy and easy
  to drift. This fixture takes the same legacy-shape kwargs and emits
  a properly populated `%Struct{}`.

  Conversions:
    * `:role` / `:start_cmd` / `:metadata` go into `settings` under their
      plain key (no `_legacy.` prefix — that prefix was M-3/M-4 dead code).
    * `:chats` accepts both legacy string-keyed maps
      (`%{"chat_id" => ..., "app_id" => ..., "kind" => "dm"}`) and the
      new atom-keyed shape; output is always atom-keyed.
    * `:id` defaults to a fresh UUID v4 if not supplied.
    * `:agent` defaults to "cc"; `:owner` defaults to "test".
    * `:transient` and `:location` honored if supplied.

  Use only in tests; not loaded into the production app
  (`elixirc_paths(:test) -> ["lib", "test/support"]`).
  """

  alias Esr.Resource.Workspace.Struct, as: WSStruct

  @type kwarg_input :: keyword() | map()

  @spec build(kwarg_input()) :: WSStruct.t()
  def build(args) when is_list(args), do: build(Enum.into(args, %{}))

  def build(%{} = args) do
    %WSStruct{
      id: Map.get(args, :id) || UUID.uuid4(),
      name: Map.fetch!(args, :name),
      owner: Map.get(args, :owner, "test"),
      folders: Map.get(args, :folders, []),
      agent: Map.get(args, :agent, "cc"),
      settings: build_settings(args),
      env: Map.get(args, :env, %{}),
      chats: normalize_chats(Map.get(args, :chats, [])),
      transient: Map.get(args, :transient, false),
      location: Map.get(args, :location)
    }
  end

  defp build_settings(args) do
    base = Map.get(args, :settings, %{})

    base
    |> maybe_put("role", Map.get(args, :role))
    |> maybe_put("start_cmd", Map.get(args, :start_cmd))
    |> maybe_put("metadata", Map.get(args, :metadata))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, _key, %{} = m) when map_size(m) == 0, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_chats(chats) when is_list(chats) do
    Enum.map(chats, &normalize_chat/1)
  end

  defp normalize_chats(_), do: []

  defp normalize_chat(%{"chat_id" => cid, "app_id" => aid} = m) do
    base = %{chat_id: cid, app_id: aid, kind: m["kind"] || "dm"}

    if m["name"] do
      Map.put(base, :name, m["name"])
    else
      base
    end
  end

  defp normalize_chat(%{chat_id: _, app_id: _} = m), do: m
  defp normalize_chat(other), do: other

  @doc """
  Tear down a workspace registered under `name` via the public Registry
  API. Replaces the M-3-era `:ets.delete(:esr_workspaces, name)` cleanup
  pattern (which targeted the deleted `@legacy_table`).

  Idempotent — returns `:ok` whether or not the workspace exists; a
  missing NameIndex ETS table is also tolerated (admin-CLI / unit
  setups that don't boot the Registry).
  """
  @spec delete!(String.t()) :: :ok
  def delete!(name) when is_binary(name) do
    case Esr.Resource.Workspace.NameIndex.id_for_name(:esr_workspace_name_index, name) do
      {:ok, id} ->
        _ = Esr.Resource.Workspace.Registry.delete_by_id(id)
        :ok

      :not_found ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Wipe both the UUID-keyed `:esr_workspaces_uuid` ETS table and the
  matching `:esr_workspace_name_index` NameIndex. Replaces the M-3-era
  `:ets.delete_all_objects(:esr_workspaces)` cleanup pattern that
  targeted the deleted legacy table.

  Idempotent — survives missing tables (admin-CLI / unit setups that
  don't boot the Registry).
  """
  @spec reset!() :: :ok
  def reset! do
    try do
      :ets.delete_all_objects(:esr_workspaces_uuid)
    rescue
      ArgumentError -> :ok
    end

    try do
      :esr_workspace_name_index
      |> Esr.Resource.Workspace.NameIndex.all()
      |> Enum.each(fn {_name, id} ->
        Esr.Resource.Workspace.NameIndex.delete_by_id(:esr_workspace_name_index, id)
      end)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end
end
