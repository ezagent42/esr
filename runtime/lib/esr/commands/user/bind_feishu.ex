defmodule Esr.Commands.User.BindFeishu do
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
        {:error,
         %{
           "type" => "user_not_found",
           "message" => "user '#{name}' not found; run `user_add name=#{name}` first"
         }}

      already_bound_to?(users, name, fid) ->
        {:ok, %{"text" => "#{fid} already bound to #{name}"}}

      bound_to_other?(users, name, fid) ->
        other = find_other_owner(users, name, fid)

        {:error,
         %{
           "type" => "feishu_id_in_use",
           "message" =>
             "feishu_id #{fid} is already bound to '#{other}'; unbind it first"
         }}

      true ->
        updated_users = append_id(users, name, fid)
        updated_doc = Map.put(doc, "users", updated_users)

        case Esr.Yaml.Writer.write(path, updated_doc) do
          :ok -> {:ok, %{"text" => "bound #{fid} to esr user #{name}"}}
          {:error, reason} -> {:error, %{"type" => "write_failed", "detail" => inspect(reason)}}
        end
    end
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" =>
         "user_bind_feishu requires args.name and args.feishu_user_id (non-empty strings)"
     }}
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
end
