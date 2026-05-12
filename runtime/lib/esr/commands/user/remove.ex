defmodule Esr.Commands.User.Remove do
  @moduledoc """
  `user_remove` admin-queue command — remove an esr user (and all feishu
  bindings) from `users.yaml`. Mirrors Python `esr user remove <name>`.

  Does NOT cascade-delete capabilities granted to the user — operator
  runs `esr cap revoke` (or `cap_revoke` slash) separately for cleanup.

  Also removes the user from `Esr.Entity.User.NameIndex` so that
  subsequent `/session:share user=<name>` calls return `user_not_found`
  immediately.

  Phase B-3 of the Phase 3/4 finish (2026-05-05).
  fix/user-name-index-population: wire NameIndex cleanup on remove.
  """

  use Esr.Commands.Meta

  command :user_remove do
    slash         :none
    category      "Users"
    description   "移除 esr user（同时清理 NameIndex；不级联撤销 cap）"
    permission    "user.manage"
    requires_user_binding      false
    requires_workspace_binding false

    arg :name, required: true, doc: "username"

    error :not_found,     "user '%{name}' not found"
    error :invalid_args,  "user_remove requires args.name (non-empty string)"
    error :write_failed,  "%{detail}"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"name" => name}}) when is_binary(name) and name != "" do
    path = Esr.Paths.users_yaml()
    doc = read_or_empty(path)

    users = Map.get(doc, "users") || %{}

    if not Map.has_key?(users, name) do
      Render.error(__MODULE__.command_meta(), :not_found, %{name: name})
    else
      # Resolve UUID before removal so URI store can drop the entity row.
      uuid_before = Esr.Uri.Compat.uuid_for_user_name(name)

      updated_users = Map.delete(users, name)
      updated_doc = Map.put(doc, "users", updated_users)

      case Esr.Yaml.Writer.write(path, updated_doc) do
        :ok ->
          # Drop URI store rows for this user. Best-effort: the next FileLoader
          # reload would reconcile, but we want the deletion visible immediately.
          case uuid_before do
            {:ok, uuid} ->
              _ = Esr.Uri.delete("esr://localhost/users/" <> uuid)
              _ = Esr.Uri.delete("esr://localhost/users/by-name/" <> name)

            _ ->
              :ok
          end

          {:ok, %{"text" => "removed esr user #{name}"}}

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
end
