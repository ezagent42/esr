defmodule Esr.Commands.User.Add do
  @moduledoc """
  `user_add` admin-queue command — register a new esr user with no
  feishu binding. Mirrors Python `esr user add <name>`.

  Writes `users.yaml` directly; the file Watcher reloads
  `Esr.Entity.User.Registry` automatically.

  Also assigns a UUID v4, writes `users/<uuid>/user.json`, and
  populates `Esr.Entity.User.NameIndex` so that `/session:share
  user=<name>` resolves immediately without waiting for a file-watcher
  reload cycle.

  Phase B-3 of the Phase 3/4 finish (2026-05-05).
  fix/user-name-index-population: wire NameIndex on add.
  """

  @behaviour Esr.Role.Control

  require Logger

  alias Esr.Entity.User.NameIndex

  @username_regex ~r/^[A-Za-z0-9][A-Za-z0-9_\-]*$/

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"name" => name}}) when is_binary(name) and name != "" do
    cond do
      not Regex.match?(@username_regex, name) ->
        {:error,
         %{
           "type" => "invalid_args",
           "message" =>
             "username #{inspect(name)} must match #{inspect(Regex.source(@username_regex))} " <>
               "(ASCII alphanumeric, optionally with - and _)"
         }}

      true ->
        path = Esr.Paths.users_yaml()
        doc = read_or_empty(path)

        users = Map.get(doc, "users") || %{}

        if Map.has_key?(users, name) do
          {:error, %{"type" => "already_exists", "message" => "user '#{name}' already exists"}}
        else
          uuid = UUID.uuid4()
          ws_uuid = UUID.uuid4()
          ws_name = "#{name}-default"

          updated_users = Map.put(users, name, %{"feishu_ids" => []})
          updated_doc = Map.put(doc, "users", updated_users)

          with :ok <- Esr.Yaml.Writer.write(path, updated_doc),
               :ok <- write_user_json(uuid, name, ws_uuid),
               :ok <- sync_reload_user_registry(path),
               :ok <- create_user_default_workspace(ws_uuid, ws_name, name),
               :ok <- Esr.Entity.User.Registry.set_default_workspace(name, ws_uuid) do
            populate_name_index(name, uuid)

            {:ok,
             %{
               "text" => "added esr user #{name}",
               "id" => uuid,
               "default_workspace" => ws_name,
               "default_workspace_id" => ws_uuid
             }}
          else
            {:error, reason} -> {:error, %{"type" => "write_failed", "detail" => inspect(reason)}}
          end
        end
    end
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "user_add requires args.name (non-empty string)"
     }}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp read_or_empty(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{} = m} -> m
      _ -> %{"users" => %{}}
    end
  end

  defp write_user_json(uuid, username, default_workspace_id) do
    dir = Path.join(Esr.Paths.users_dir(), uuid)

    with :ok <- File.mkdir_p(dir) do
      path = Path.join(dir, "user.json")
      tmp = path <> ".tmp"

      doc = %{
        "schema_version" => 1,
        "id" => uuid,
        "username" => username,
        "display_name" => "",
        "feishu_ids" => [],
        "default_workspace_id" => default_workspace_id,
        "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      with :ok <- File.write(tmp, Jason.encode!(doc, pretty: true)),
           :ok <- File.rename(tmp, path) do
        :ok
      end
    end
  rescue
    e -> {:error, e}
  end

  # The Watcher (FSEvents-based) reloads `User.Registry` asynchronously on
  # users.yaml change events. Inside this command we need the new user to
  # appear in `:esr_users_by_name` *before* `set_default_workspace/2` runs,
  # otherwise that call returns `{:error, :not_found}`. Calling
  # `FileLoader.load/1` synchronously here makes the with-chain atomic.
  defp sync_reload_user_registry(yaml_path) do
    case Esr.Entity.User.FileLoader.load(yaml_path) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  rescue
    e -> {:error, e}
  end

  defp create_user_default_workspace(ws_uuid, ws_name, owner) do
    dir = Esr.Paths.workspace_dir(ws_name)

    with :ok <- File.mkdir_p(dir) do
      ws = %Esr.Resource.Workspace.Struct{
        id: ws_uuid,
        name: ws_name,
        owner: owner,
        folders: [],
        agent: "cc",
        settings: %{},
        env: %{},
        chats: [],
        transient: false,
        location: {:esr_bound, dir}
      }

      Esr.Resource.Workspace.Registry.put(ws)
    end
  rescue
    e -> {:error, e}
  end

  defp populate_name_index(name, uuid) do
    case NameIndex.put(:esr_user_name_index, name, uuid) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "User.Add: NameIndex.put failed for #{inspect(name)} / #{inspect(uuid)}: #{inspect(reason)}"
        )
    end
  end
end
