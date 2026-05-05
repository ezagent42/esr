defmodule Esr.Commands.User.UnbindFeishu do
  @moduledoc """
  `user_unbind_feishu` admin-queue command — remove a feishu open_id
  binding from an esr user. Mirrors Python `esr user unbind-feishu`
  but **without** the bootstrap-cap auto-revoke (transitional Python
  logic; see `Esr.Commands.User.BindFeishu` moduledoc).

  Phase B-3 of the Phase 3/4 finish (2026-05-05).
  """

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"name" => name, "feishu_user_id" => fid}})
      when is_binary(name) and name != "" and is_binary(fid) and fid != "" do
    path = Esr.Paths.users_yaml()
    doc = read_or_empty(path)

    users = Map.get(doc, "users") || %{}

    cond do
      not Map.has_key?(users, name) ->
        {:error, %{"type" => "user_not_found", "message" => "user '#{name}' not found"}}

      not bound?(users, name, fid) ->
        {:error,
         %{"type" => "binding_not_found", "message" => "#{fid} not bound to #{name}"}}

      true ->
        updated_users = remove_id(users, name, fid)
        updated_doc = Map.put(doc, "users", updated_users)

        case Esr.Yaml.Writer.write(path, updated_doc) do
          :ok -> {:ok, %{"text" => "unbound #{fid} from esr user #{name}"}}
          {:error, reason} -> {:error, %{"type" => "write_failed", "detail" => inspect(reason)}}
        end
    end
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" =>
         "user_unbind_feishu requires args.name and args.feishu_user_id (non-empty strings)"
     }}
  end

  defp read_or_empty(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{} = m} -> m
      _ -> %{"users" => %{}}
    end
  end

  defp bound?(users, name, fid) do
    case Map.get(users, name) do
      nil -> false
      row -> fid in (Map.get(row, "feishu_ids") || [])
    end
  end

  defp remove_id(users, name, fid) do
    row = Map.get(users, name) || %{}
    ids = Map.get(row, "feishu_ids") || []
    Map.put(users, name, Map.put(row, "feishu_ids", List.delete(ids, fid)))
  end
end
