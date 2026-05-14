defmodule Esr.Plugins.Feishu.Commands.BindUser do
  @moduledoc """
  `user_bind_feishu` admin-queue command — bind a feishu open_id to an
  esr user. Mirrors Python `esr user bind-feishu <name> <feishu_user_id>`
  but **without** the bootstrap-cap auto-grant + ou_xxx → username
  migration that Python performs.

  The auto-grant logic is transitional, tied to the legacy ou_xxx-keyed
  capabilities scheme. Once the pure-username-caps spec (#238) lands,
  bootstrap-cap auto-grant becomes redundant. Until then, operators
  port the auto-grant manually via `esr cap grant`. The migration of
  pre-existing ou_xxx caps becomes a one-shot data migration handled
  by the username-caps PR, not by user binding.

  Phase B-3 of the Phase 3/4 finish (2026-05-05).
  """

  use Esr.Commands.Meta

  command :feishu_bind do
    slash         :none
    category      "Plugins"
    description   "把 feishu open_id 绑定到 esr user"
    permission    "feishu/user-bind"
    requires_user_binding      false
    requires_workspace_binding false

    arg :name,           required: true, doc: "esr 用户名"
    arg :feishu_user_id, required: true, doc: "feishu open_id"

    error :invalid_args,     "user_bind_feishu requires args.name and args.feishu_user_id (non-empty strings)"
    error :user_not_found,   "user '%{name}' not found; run `user_add name=%{name}` first"
    error :feishu_id_in_use, "feishu_id %{fid} is already bound to '%{other}'; unbind it first"
    error :write_failed,     "%{detail}"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"name" => name, "feishu_user_id" => fid}})
      when is_binary(name) and name != "" and is_binary(fid) and fid != "" do
    path = Esr.Paths.users_yaml()
    doc = read_or_empty(path)

    users = Map.get(doc, "users") || %{}

    cond do
      not Map.has_key?(users, name) ->
        Render.error(__MODULE__.command_meta(), :user_not_found, %{name: name})

      already_bound_to?(users, name, fid) ->
        {:ok, %{"text" => "#{fid} already bound to #{name}"}}

      bound_to_other?(users, name, fid) ->
        other = find_other_owner(users, name, fid)

        Render.error(__MODULE__.command_meta(), :feishu_id_in_use, %{fid: fid, other: other})

      true ->
        updated_users = append_id(users, name, fid)
        updated_doc = Map.put(doc, "users", updated_users)

        case Esr.Yaml.Writer.write(path, updated_doc) do
          :ok ->
            # Walkthrough-4 C10: keep the per-user `user.json` in sync.
            # users.yaml is the SOT for routing, but consumers that look
            # at user.json directly (e.g. operator inspection) see stale
            # `feishu_ids: []` without this step. Non-fatal — bind still
            # succeeds even if user.json sync fails, but we log so it's
            # visible.
            sync_user_json(name, fid)

            # Walkthrough-4 C5-B: pre-fix this handler wrote yaml and
            # returned without touching the URI store, so the in-memory
            # NameIndex / Registry was stale until either FSEvents
            # fired the watcher (race-y) or the operator restarted
            # esrd. Force a synchronous reload so subsequent `/doctor`
            # and inbound envelopes see the new binding immediately.
            _ = Esr.Entity.User.FileLoader.load(path)

            {:ok, %{"text" => "bound #{fid} to esr user #{name}"}}

          {:error, reason} ->
            Render.error(__MODULE__.command_meta(), :write_failed, %{detail: inspect(reason)})
        end
    end
  end

  def execute(_cmd) do
    Render.error(__MODULE__.command_meta(), :invalid_args)
  end

  defp read_or_empty(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{} = m} -> m
      _ -> %{"users" => %{}}
    end
  end

  defp already_bound_to?(users, name, fid) do
    case Map.get(users, name) do
      nil -> false
      row -> fid in (Map.get(row, "feishu_ids") || [])
    end
  end

  defp bound_to_other?(users, exclude_name, fid) do
    Enum.any?(users, fn {n, row} ->
      n != exclude_name and is_map(row) and fid in (Map.get(row, "feishu_ids") || [])
    end)
  end

  defp find_other_owner(users, exclude_name, fid) do
    {n, _} =
      Enum.find(users, fn {n, row} ->
        n != exclude_name and is_map(row) and fid in (Map.get(row, "feishu_ids") || [])
      end)

    n
  end

  defp append_id(users, name, fid) do
    row = Map.get(users, name) || %{}
    ids = Map.get(row, "feishu_ids") || []
    Map.put(users, name, Map.put(row, "feishu_ids", ids ++ [fid]))
  end

  # Walkthrough-4 C10. users.yaml is the routing SOT but `user.json`
  # under `users/<uuid>/` mirrors the same fields for operator
  # inspection + future read paths that prefer the per-user file.
  # Find the user's `user.json` by scanning `users/` (the canonical
  # path uses UUID-as-dirname, which we don't know from `name` alone
  # without the URI store), update `feishu_ids`, atomically replace.
  #
  # Idempotent: if `fid` is already in the list, no-op (skips the
  # write). Returns `:ok | {:error, reason}` but the caller logs +
  # discards the result — keep the bind successful even if disk sync
  # fails on this side path.
  defp sync_user_json(name, fid) do
    case find_user_json_path(name) do
      {:ok, json_path} ->
        update_user_json(json_path, fid)

      :not_found ->
        require Logger

        Logger.warning(
          "feishu_bind: cannot sync user.json for #{name}: no users/<uuid>/user.json with matching username"
        )

        {:error, :user_json_not_found}
    end
  end

  defp find_user_json_path(target_name) do
    users_dir = Esr.Paths.users_dir()

    if File.dir?(users_dir) do
      users_dir
      |> File.ls!()
      |> Enum.find_value(:not_found, fn entry ->
        json_path = Path.join([users_dir, entry, "user.json"])

        with true <- File.exists?(json_path),
             {:ok, content} <- File.read(json_path),
             {:ok, %{"username" => ^target_name}} <- Jason.decode(content) do
          {:ok, json_path}
        else
          _ -> nil
        end
      end)
    else
      :not_found
    end
  rescue
    _ -> :not_found
  end

  defp update_user_json(json_path, fid) do
    with {:ok, content} <- File.read(json_path),
         {:ok, %{} = doc} <- Jason.decode(content) do
      existing_ids = Map.get(doc, "feishu_ids") || []

      if fid in existing_ids do
        :ok
      else
        updated = Map.put(doc, "feishu_ids", existing_ids ++ [fid])
        encoded = Jason.encode!(updated, pretty: true)

        # Atomic write — tmp + rename — to match `user_add`'s pattern.
        tmp = json_path <> ".tmp.#{:rand.uniform(999_999_999)}"

        with :ok <- File.write(tmp, encoded),
             :ok <- File.rename(tmp, json_path) do
          :ok
        end
      end
    end
  rescue
    e -> {:error, e}
  end
end
