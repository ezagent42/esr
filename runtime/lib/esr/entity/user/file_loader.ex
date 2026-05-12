defmodule Esr.Entity.User.FileLoader do
  @moduledoc """
  Parse `users.yaml` + per-uuid `users/<uuid>/user.json` and populate
  the URI store (`:esr_uri_store`) with user entity rows + aliases.

  PR-1 (URI identity migration, 2026-05-12) replaced the previous
  `Esr.Entity.User.Registry.load_snapshot_with_uuids/2` + NameIndex
  population with direct `Esr.Uri.put_entity/3` + `Esr.Uri.alias/2`
  calls. Same yaml schema, same disk layout — only the in-memory
  destination changed.

  Schema:

      users:
        linyilun:
          feishu_ids:
            - ou_6b11faf8e93aedfb9d3857b9cc23b9e7
        yaoshengyue:
          feishu_ids:
            - ou_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

  URI store layout (per user):
    - canonical:  esr://localhost/users/<uuid>          → %User.Struct{}
    - by-name:    esr://localhost/users/by-name/<name>  → alias
    - feishu:     esr://localhost/users/feishu/<ou_id>  → alias  (one per id)

  Validation:
  - Each top-level key in users.yaml is a username (ASCII alphanumeric
    + `-` + `_`, enforced at write time by the CLI; loader logs a
    warning if it sees something else but still admits the entry).
  - `feishu_ids:` must be a list of strings; absent / empty is legal.

  Load is non-destructive on parse failure: the prior URI store rows
  for kind `:user` are kept and the caller sees the specific error.

  When `users.yaml` is absent (clean state) the loader falls back to
  scanning the `users/` directory directly so the URI store is still
  populated from persisted `user.json` files.
  """

  @behaviour Esr.Role.Control
  require Logger

  alias Esr.Entity.User.Struct, as: User

  @username_re ~r/^[A-Za-z0-9][A-Za-z0-9_\-]*$/

  @spec load(Path.t()) :: :ok | {:error, term()}
  def load(path) do
    users_dir = Path.dirname(path) |> Path.join("users")

    cond do
      not File.exists?(path) ->
        # No users.yaml — load from users/ directory directly if it exists.
        {snapshot, uuids} = load_from_users_dir(users_dir)
        populate_uri_store(snapshot, uuids, %{})
        :ok

      true ->
        with {:ok, yaml} <- parse(path),
             {:ok, snapshot} <- build_snapshot(yaml) do
          uuids = read_uuids_from_dir(users_dir)
          defaults = read_default_workspaces_from_dir(users_dir)
          populate_uri_store(snapshot, uuids, defaults)
          Logger.info("users: loaded #{map_size(snapshot)} users from #{path}")
          :ok
        else
          {:error, reason} = err ->
            Logger.error(
              "users: load failed (#{inspect(reason)}); keeping previous URI store rows"
            )

            err
        end
    end
  end

  # ---------------------------------------------------------------------------
  # URI store population
  # ---------------------------------------------------------------------------

  # Clear every :user entity (+ its aliases), then write the fresh set.
  # Inside-one-process atomicity matches old Registry.load_snapshot semantics
  # well enough for boot-time + Watcher-triggered reloads. See spec P1-1.
  defp populate_uri_store(snapshot, uuids, defaults) do
    if uri_store_alive?() do
      _ = Esr.Uri.Store.delete_all_by_kind(:user)

      Enum.each(snapshot, fn {username, %User{feishu_ids: ids} = user} ->
        case Map.get(uuids, username) do
          nil ->
            # No UUID assigned yet — user is in yaml but has no user.json.
            # Skip URI store population; the next /user:add or external write
            # of user.json will close the gap.
            :ok

          uuid ->
            # Merge default_workspace_id from defaults map if present
            user_with_default =
              case Map.get(defaults, username) do
                ws_id when is_binary(ws_id) and ws_id != "" ->
                  %User{user | default_workspace_id: ws_id}

                _ ->
                  user
              end

            canonical = "esr://localhost/users/" <> uuid
            :ok = Esr.Uri.put_entity(canonical, :user, user_with_default)

            _ =
              Esr.Uri.alias(canonical, "esr://localhost/users/by-name/" <> username)

            Enum.each(ids, fn ou_id ->
              _ = Esr.Uri.alias(canonical, "esr://localhost/users/feishu/" <> ou_id)
            end)
        end
      end)
    else
      Logger.warning("users: Esr.Uri.Store not running; skipping URI store population")
    end

    :ok
  end

  defp uri_store_alive? do
    case Process.whereis(Esr.Uri.Store) do
      pid when is_pid(pid) -> true
      _ -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers — yaml / json parsing (unchanged from pre-PR-1)
  # ---------------------------------------------------------------------------

  defp parse(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, yaml} -> {:ok, yaml}
      {:error, err} -> {:error, {:yaml_parse, err}}
    end
  end

  defp build_snapshot(yaml) when is_map(yaml) do
    users = Map.get(yaml, "users") || %{}

    case users do
      %{} = m ->
        snapshot =
          Enum.reduce(m, %{}, fn {username, row}, acc ->
            unless Regex.match?(@username_re, username) do
              Logger.warning(
                "users: username #{inspect(username)} does not match #{inspect(@username_re)} (admitted anyway)"
              )
            end

            ids = (is_map(row) && row["feishu_ids"]) || []
            Map.put(acc, username, %User{username: username, feishu_ids: ids})
          end)

        {:ok, snapshot}

      _other ->
        {:error, {:malformed, "users: must be a map"}}
    end
  end

  defp build_snapshot(_), do: {:error, {:malformed, "top level must be a map"}}

  # Scan `<inst>/users/<uuid>/user.json` files and return a `%{username => uuid}` map.
  # Non-fatal: missing directory or malformed JSON entries are skipped with a warning.
  @spec read_uuids_from_dir(Path.t()) :: %{String.t() => String.t()}
  def read_uuids_from_dir(users_dir) do
    if File.dir?(users_dir) do
      users_dir
      |> File.ls!()
      |> Enum.reduce(%{}, fn entry, acc ->
        json_path = Path.join([users_dir, entry, "user.json"])

        case read_user_json(json_path) do
          {:ok, %{"username" => username, "id" => uuid}}
          when is_binary(username) and is_binary(uuid) ->
            Map.put(acc, username, uuid)

          _ ->
            acc
        end
      end)
    else
      %{}
    end
  rescue
    e ->
      Logger.warning("users: failed to scan users dir #{users_dir}: #{inspect(e)}")
      %{}
  end

  # Companion to read_uuids_from_dir/1: scan the same files for
  # default_workspace_id. Returns %{username => ws_uuid}.
  @spec read_default_workspaces_from_dir(Path.t()) :: %{String.t() => String.t()}
  def read_default_workspaces_from_dir(users_dir) do
    if File.dir?(users_dir) do
      users_dir
      |> File.ls!()
      |> Enum.reduce(%{}, fn entry, acc ->
        json_path = Path.join([users_dir, entry, "user.json"])

        case read_user_json(json_path) do
          {:ok, %{"username" => username, "default_workspace_id" => ws_id}}
          when is_binary(username) and is_binary(ws_id) ->
            Map.put(acc, username, ws_id)

          _ ->
            acc
        end
      end)
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  # Load from users/ directory when no users.yaml exists (post-migration state).
  # Returns {snapshot, uuids} where snapshot is built from user.json files.
  @spec load_from_users_dir(Path.t()) :: {%{String.t() => User.t()}, %{String.t() => String.t()}}
  defp load_from_users_dir(users_dir) do
    if File.dir?(users_dir) do
      users_dir
      |> File.ls!()
      |> Enum.reduce({%{}, %{}}, fn entry, {snap, uuids} ->
        json_path = Path.join([users_dir, entry, "user.json"])

        case read_user_json(json_path) do
          {:ok, %{"username" => username, "id" => uuid} = doc}
          when is_binary(username) and is_binary(uuid) ->
            feishu_ids = Map.get(doc, "feishu_ids", [])
            default_ws = Map.get(doc, "default_workspace_id")

            user = %User{
              username: username,
              feishu_ids: feishu_ids,
              default_workspace_id: default_ws
            }

            {Map.put(snap, username, user), Map.put(uuids, username, uuid)}

          _ ->
            {snap, uuids}
        end
      end)
    else
      {%{}, %{}}
    end
  rescue
    e ->
      Logger.warning("users: failed to load from users dir #{users_dir}: #{inspect(e)}")
      {%{}, %{}}
  end

  defp read_user_json(path) do
    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, parsed} <- Jason.decode(content) do
      {:ok, parsed}
    else
      _ -> :error
    end
  end
end
