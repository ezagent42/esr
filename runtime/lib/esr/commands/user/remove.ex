defmodule Esr.Commands.User.Remove do
  @moduledoc """
  `user_remove` admin-queue command — remove an esr user (and all feishu
  bindings) from `users.yaml`. Mirrors Python `esr user remove <name>`.

  Does NOT cascade-delete capabilities granted to the user — operator
  runs `esr cap revoke` (or `cap_revoke` slash) separately for cleanup.

  Phase B-3 of the Phase 3/4 finish (2026-05-05).
  """

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"name" => name}}) when is_binary(name) and name != "" do
    path = Esr.Paths.users_yaml()
    doc = read_or_empty(path)

    users = Map.get(doc, "users") || %{}

    if not Map.has_key?(users, name) do
      {:error, %{"type" => "not_found", "message" => "user '#{name}' not found"}}
    else
      updated_users = Map.delete(users, name)
      updated_doc = Map.put(doc, "users", updated_users)

      case Esr.Yaml.Writer.write(path, updated_doc) do
        :ok -> {:ok, %{"text" => "removed esr user #{name}"}}
        {:error, reason} -> {:error, %{"type" => "write_failed", "detail" => inspect(reason)}}
      end
    end
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "user_remove requires args.name (non-empty string)"
     }}
  end

  defp read_or_empty(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{} = m} -> m
      _ -> %{"users" => %{}}
    end
  end
end
