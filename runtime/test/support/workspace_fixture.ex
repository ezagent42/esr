defmodule Esr.Test.WorkspaceFixture do
  @moduledoc """
  PR-2 (2026-05-12 URI identity migration) drop-in replacement for the
  pre-M-4 `%Esr.Resource.Workspace.Registry.Workspace{}` struct
  constructor + Workspace.Registry-touching cleanup helpers.

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

  After M-4 the legacy struct is gone; after PR-2 the legacy ETS tables
  (`:esr_workspaces_uuid`, `:esr_workspace_name_index{,_name_to_id,_id_to_name}`)
  are gone too. Workspaces live in `:esr_uri_store` as `(:entity, :workspace, %Struct{})`
  rows plus by-name + by-chat aliases. This fixture mirrors the disk →
  URI store population that `Esr.Resource.Workspace.FileLoader.populate_uri_store/0`
  does at boot, but driven from a struct in test setup blocks.

  Conversions:
    * `:role` / `:start_cmd` / `:metadata` go into `settings` under their
      plain key.
    * `:chats` accepts both legacy string-keyed maps and atom-keyed shape;
      output is always atom-keyed.
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
  Insert (or replace) the given workspace into the URI store. Mirrors
  what `Esr.Resource.Workspace.FileLoader.populate_uri_store/0` does at
  boot, scoped to a single struct so tests can seed deterministic
  fixtures without touching disk.

  Writes:
    - canonical:  esr://localhost/workspaces/<id>          → %Struct{}
    - by-name:    esr://localhost/workspaces/by-name/<name> → alias
    - by-chat:    esr://localhost/workspaces/by-chat/<cid>/<aid> → alias (each chat)

  Raises if `Esr.Uri.Store` isn't running (caller must
  `start_supervised!({Esr.Uri.Store, []})` in setup or rely on the
  Application supervisor).
  """
  @spec put!(WSStruct.t()) :: :ok
  def put!(%WSStruct{} = ws) do
    ensure_uri_store!()
    :ok = Esr.Uri.Compat.workspace_put(ws)
    :ok
  rescue
    # workspace_put writes to disk too; tests that don't care about disk
    # may have set location: nil — that path is a no-op so this rescue
    # only triggers on truly broken setups. Re-raise loudly.
    err -> reraise err, __STACKTRACE__
  end

  @doc """
  Build + put! in one call. Returns the inserted %Struct{}.
  """
  @spec build_and_put!(kwarg_input()) :: WSStruct.t()
  def build_and_put!(args) do
    ws = build(args)
    :ok = put!(ws)
    ws
  end

  @doc """
  Tear down a workspace registered under `name`. Replaces the M-3-era
  `:ets.delete(:esr_workspaces, name)` cleanup pattern. Idempotent —
  returns `:ok` whether or not the workspace exists.
  """
  @spec delete!(String.t()) :: :ok
  def delete!(name) when is_binary(name) do
    case Esr.Uri.Compat.uuid_for_workspace_name(name) do
      {:ok, id} ->
        _ = Esr.Uri.Compat.workspace_delete_by_id(id)
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
  Wipe every `:workspace` entity row + its aliases from the URI store.
  Replaces the M-3-era `:ets.delete_all_objects(:esr_workspaces)` pattern.

  Idempotent — survives missing tables.
  """
  @spec reset!() :: :ok
  def reset! do
    if Process.whereis(Esr.Uri.Store) do
      Esr.Uri.Store.delete_all_by_kind(:workspace)
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp ensure_uri_store! do
    case Process.whereis(Esr.Uri.Store) do
      pid when is_pid(pid) ->
        :ok

      _ ->
        raise "Esr.Uri.Store not running; tests using Esr.Test.WorkspaceFixture must " <>
                "either start_supervised!({Esr.Uri.Store, []}) in setup, or run " <>
                "with the application supervisor up"
    end
  end
end
