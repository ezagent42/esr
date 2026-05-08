defmodule Esr.Commands.Adapters.List do
  @moduledoc """
  `/adapters list` slash command — list configured adapter instances
  from `~/.esrd/<env>/adapters.yaml`. Pure file read; no runtime
  dependency beyond `Esr.Paths.adapters_yaml/0`.

  Migrated from the Python `esr adapters list`. Output format:

      <instance_name>  type=<type>  [app_id=<id>] [base_url=<url>]

  One line per instance. Empty file / missing file / no `instances`
  key → "no adapter instances configured". The escript catches
  `esr adapters list` via sub-action concatenation
  (`adapters_list`) — no escript-side wiring needed beyond this
  module.
  """

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()}

  @spec execute(map()) :: result()
  def execute(_cmd) do
    text =
      case read_yaml() do
        {:ok, instances} when instances != %{} ->
          instances
          |> Enum.sort_by(fn {name, _} -> name end)
          |> Enum.map_join("\n", &format_row/1)

        _ ->
          "no adapter instances configured"
      end

    {:ok, %{"text" => text}}
  end

  defp read_yaml do
    path = Esr.Paths.adapters_yaml()

    cond do
      not File.exists?(path) ->
        :no_file

      true ->
        case YamlElixir.read_from_file(path) do
          {:ok, doc} when is_map(doc) ->
            {:ok, doc["instances"] || %{}}

          _ ->
            :no_file
        end
    end
  end

  defp format_row({name, entry}) when is_map(entry) do
    type = entry["type"] || ""
    config = entry["config"] || %{}

    parts =
      ["type=#{type}"]
      |> maybe_append(config["app_id"], &"app_id=#{&1}")
      |> maybe_append(config["base_url"], &"base_url=#{&1}")

    "#{name}  " <> Enum.join(parts, "  ")
  end

  defp format_row({name, _}), do: "#{name}  (malformed entry)"

  defp maybe_append(parts, nil, _formatter), do: parts
  defp maybe_append(parts, value, formatter), do: parts ++ [formatter.(value)]
end
