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
  """

  @behaviour Esr.Role.Control
  require Logger

  alias Esr.Entity.User.Registry
  alias Esr.Entity.User.Registry.User

  @username_re ~r/^[A-Za-z0-9][A-Za-z0-9_\-]*$/

  @spec load(Path.t()) :: :ok | {:error, term()}
  def load(path) do
    cond do
      not File.exists?(path) ->
        Registry.load_snapshot(%{})
        :ok

      true ->
        with {:ok, yaml} <- parse(path),
             {:ok, snapshot} <- build_snapshot(yaml) do
          Registry.load_snapshot(snapshot)
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
end
