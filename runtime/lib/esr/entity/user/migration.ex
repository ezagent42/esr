defmodule Esr.Entity.User.Migration do
  @moduledoc """
  Boot migration: `users.yaml` → per-user `users/<uuid>/user.json` + `.esr/workspace.json`.

  Called once at boot by `Esr.Entity.User.FileLoader.load/1` when
  `users.yaml` exists and the `users/` directory is absent or empty.

  Behavior:
  1. Parse `users.yaml` (existing format: `users: { <username>: { feishu_ids: [...] } }`).
  2. For each user entry: assign UUID v4, write `users/<uuid>/user.json`,
     write `users/<uuid>/.esr/workspace.json` (user-default workspace stub).
  3. Atomically rename `users.yaml` → `users.yaml.migrated-<unix_timestamp>`.

  Idempotent: if `users.yaml` is absent (already renamed), returns `:ok` immediately.
  Non-destructive: rename preserves the original YAML as a backup.
  """

  require Logger

  @spec run(String.t()) :: :ok | {:error, term()}
  def run(inst_dir) do
    yaml_path = Path.join(inst_dir, "users.yaml")

    if File.exists?(yaml_path) do
      do_migrate(inst_dir, yaml_path)
    else
      :ok
    end
  end

  defp do_migrate(inst_dir, yaml_path) do
    with {:ok, yaml} <- YamlElixir.read_from_file(yaml_path),
         {:ok, users} <- extract_users(yaml) do
      Enum.each(users, fn {username, row} ->
        uuid = UUID.uuid4()
        feishu_ids = (is_map(row) && row["feishu_ids"]) || []
        write_user_json(inst_dir, uuid, username, feishu_ids)
        write_workspace_stub(inst_dir, uuid, username)
      end)

      ts = System.system_time(:second)
      backup = yaml_path <> ".migrated-#{ts}"
      File.rename!(yaml_path, backup)
      Logger.info("user.migration: migrated #{length(users)} users; backup at #{backup}")
      :ok
    end
  end

  defp extract_users(%{"users" => users}) when is_map(users), do: {:ok, Map.to_list(users)}
  defp extract_users(_), do: {:ok, []}

  defp write_user_json(inst_dir, uuid, username, _feishu_ids) do
    dir = Path.join([inst_dir, "users", uuid])
    File.mkdir_p!(dir)
    path = Path.join(dir, "user.json")

    doc = %{
      "schema_version" => 1,
      "id" => uuid,
      "username" => username,
      "display_name" => "",
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    tmp = path <> ".tmp"
    File.write!(tmp, Jason.encode!(doc, pretty: true))
    File.rename!(tmp, path)
  end

  defp write_workspace_stub(inst_dir, uuid, username) do
    esr_dir = Path.join([inst_dir, "users", uuid, ".esr"])
    File.mkdir_p!(esr_dir)
    path = Path.join(esr_dir, "workspace.json")

    unless File.exists?(path) do
      ws_uuid = UUID.uuid4()

      doc = %{
        "schema_version" => 1,
        "id" => ws_uuid,
        "name" => username,
        "owner" => uuid,
        "kind" => "user-default",
        "folders" => [],
        "chats" => [],
        "transient" => false,
        "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      tmp = path <> ".tmp"
      File.write!(tmp, Jason.encode!(doc, pretty: true))
      File.rename!(tmp, path)
    end
  end
end
