defmodule Esr.Entity.User.FileLoader do
  @moduledoc """
  Parse `users.yaml` + per-uuid `users/<uuid>/user.json` and populate
  the URI store (`:esr_uri_store`) with user entity rows + aliases.

  ## Single source of truth

  `users/<uuid>/user.json` is the **canonical** per-user record (UUID,
  username, feishu_ids, default_workspace_id, timestamps). `users.yaml`
  is the human-editable **index** — it carries usernames + an optional
  `feishu_ids:` hint. When a yaml entry has no matching `user.json`
  (legacy hand-edits, fixture seeds, half-finished bootstraps), this
  loader **auto-mints a UUID, writes `user.json` to disk, and proceeds**
  — there is no silent-skip path. This is the behavior Phase 1b.3's
  `Esr.Entity.User.Migration` was designed for but never wired up;
  the gap caused PR-356's `populate_uri_store/3` `nil -> :ok` branch
  which left chat-side `requires_user_binding` checks broken under
  fixture-seeded or hand-edited yaml.

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
          uuids =
            read_uuids_from_dir(users_dir)
            |> ensure_uuids_for_all(snapshot, users_dir)

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
            # Defensive safety net: ensure_uuids_for_all/3 is supposed to
            # mint UUIDs for every yaml entry before we get here, so this
            # branch should never trigger. If it does, an upstream write
            # failed (e.g. read-only users dir); log loudly so operators
            # see it instead of silently dropping the user from the URI
            # store.
            Logger.warning(
              "users: '#{username}' has no UUID even after ensure_uuids_for_all/3 " <>
                "(disk write likely failed); skipping URI store population for this entry"
            )

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
  # Auto-mint: close the yaml-without-user.json gap
  # ---------------------------------------------------------------------------

  # For every username in `snapshot` that has no matching `users/<uuid>/user.json`
  # on disk, synthesize a UUID v4, persist `user.json`, and merge the new
  # mapping into `uuids`. This is the live counterpart to Phase 1b.3's
  # `Esr.Entity.User.Migration` (which was written but never called) —
  # idempotent: subsequent loads find the user.json and skip the mint.
  #
  # Returns the merged `%{username => uuid}` map. Disk-write failures are
  # logged at error level and the entry is dropped from the returned map;
  # `populate_uri_store/3`'s defensive nil-branch then surfaces the same
  # username as a warning rather than silently disappearing.
  @spec ensure_uuids_for_all(map(), map(), Path.t()) :: map()
  defp ensure_uuids_for_all(existing_uuids, snapshot, users_dir) do
    Enum.reduce(snapshot, existing_uuids, fn {username, %User{feishu_ids: ids}}, acc ->
      case Map.get(acc, username) do
        nil ->
          uuid = UUID.uuid4()

          case write_user_json(users_dir, uuid, username, ids) do
            :ok ->
              Logger.info(
                "users: auto-minted UUID for '#{username}' (#{uuid}); wrote #{users_dir}/#{uuid}/user.json"
              )

              Map.put(acc, username, uuid)

            {:error, reason} ->
              Logger.error(
                "users: failed to write user.json for '#{username}' " <>
                  "(uuid=#{uuid}): #{inspect(reason)}; will retry next reload"
              )

              acc
          end

        _uuid ->
          acc
      end
    end)
  end

  # Same shape as `Esr.Commands.User.Add.write_user_json/3` so the file is
  # interchangeable with the canonical write path. Atomic via .tmp + rename.
  @spec write_user_json(Path.t(), String.t(), String.t(), [String.t()]) ::
          :ok | {:error, term()}
  defp write_user_json(users_dir, uuid, username, feishu_ids) do
    dir = Path.join(users_dir, uuid)

    with :ok <- File.mkdir_p(dir) do
      path = Path.join(dir, "user.json")
      tmp = path <> ".tmp"

      doc = %{
        "schema_version" => 1,
        "id" => uuid,
        "username" => username,
        "display_name" => "",
        "feishu_ids" => feishu_ids,
        "default_workspace_id" => nil,
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
