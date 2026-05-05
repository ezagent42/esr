defmodule Esr.Commands.User.Add do
  @moduledoc """
  `user_add` admin-queue command — register a new esr user with no
  feishu binding. Mirrors Python `esr user add <name>`.

  Writes `users.yaml` directly; the file Watcher reloads
  `Esr.Entity.User.Registry` automatically.

  Phase B-3 of the Phase 3/4 finish (2026-05-05).
  """

  @behaviour Esr.Role.Control

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
          updated_users = Map.put(users, name, %{"feishu_ids" => []})
          updated_doc = Map.put(doc, "users", updated_users)

          case Esr.Yaml.Writer.write(path, updated_doc) do
            :ok -> {:ok, %{"text" => "added esr user #{name}"}}
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

  defp read_or_empty(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{} = m} -> m
      _ -> %{"users" => %{}}
    end
  end
end
