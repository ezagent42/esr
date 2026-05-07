defmodule Esr.Entity.User.FileLoader do
  @moduledoc """
  Parse `users.yaml` and atomically swap the `Esr.Entity.User.Registry` snapshot.

  Schema:

      users:
        linyilun:
          feishu_ids:
            - ou_6b11faf8e93aedfb9d3857b9cc23b9e7
        yaoshengyue:
          feishu_ids:
            - ou_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

  Validation:
  - Each top-level key is a username (ASCII alphanumeric + `-` + `_`,
    enforced at write time by the CLI; the loader logs a warning if it
    sees something else but still admits the entry — operator's yaml
    edits shouldn't be rejected wholesale).
  - `feishu_ids:` must be a list of strings; absent / empty list is
    legal (user exists but has no binding yet).

  Load is non-destructive on parse failure: the prior snapshot is kept
  and the caller sees the specific error.

  UUID population (fix/user-name-index-population):
  After building the snapshot from YAML, the loader also scans the
  `users/` directory for `<uuid>/user.json` files to build a
  `%{username => uuid}` map. This map is passed to
  `Registry.load_snapshot_with_uuids/2` so that
  `Esr.Entity.User.NameIndex` is populated at boot time, enabling
  `/session:share user=<username>` to resolve usernames → UUIDs.

  When `users.yaml` is absent (pre-migration or clean state) the loader
  falls back to scanning the `users/` directory directly so that the
  NameIndex is still populated from persisted `user.json` files.
  """

  @behaviour Esr.Role.Control
  require Logger

  alias Esr.Entity.User.Registry
  alias Esr.Entity.User.Registry.User

  @username_re ~r/^[A-Za-z0-9][A-Za-z0-9_\-]*$/

  @spec load(Path.t()) :: :ok | {:error, term()}
  def load(path) do
    users_dir = Path.dirname(path) |> Path.join("users")

    cond do
      not File.exists?(path) ->
        # No users.yaml — load from users/ directory directly if it exists.
        {snapshot, uuids} = load_from_users_dir(users_dir)
        Registry.load_snapshot_with_uuids(snapshot, uuids)
        :ok

      true ->
        with {:ok, yaml} <- parse(path),
             {:ok, snapshot} <- build_snapshot(yaml) do
          uuids = read_uuids_from_dir(users_dir)
          Registry.load_snapshot_with_uuids(snapshot, uuids)
          Logger.info("users: loaded #{map_size(snapshot)} users from #{path}")
          :ok
        else
          {:error, reason} = err ->
            Logger.error(
              "users: load failed (#{inspect(reason)}); keeping previous snapshot"
            )

            err
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
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
            user = %User{username: username, feishu_ids: feishu_ids}
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
