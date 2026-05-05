defmodule Esr.Commands.Actors.Inspect do
  @moduledoc """
  `actors_inspect` slash / admin-queue command — dump a single
  actor's GenServer state by `actor_id`. Optional `field=<dotted.path>`
  drills into a specific nested key.

  Migrated from `EsrWeb.CliChannel.dispatch("cli:actors/inspect", ...)`.
  """

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"actor_id" => actor_id} = args})
      when is_binary(actor_id) and actor_id != "" do
    case Esr.Entity.Registry.lookup(actor_id) do
      {:ok, _pid} ->
        snap = Esr.Entity.Server.describe(actor_id)
        full = build_full(snap, actor_id)

        case Map.get(args, "field") do
          field when is_binary(field) and field != "" ->
            path = String.split(field, ".")

            case get_in_nested(full, path) do
              nil ->
                {:error,
                 %{
                   "type" => "field_not_present",
                   "message" => "actor #{actor_id} has no field #{field}"
                 }}

              value ->
                {:ok,
                 %{"text" => "field=#{field} value=#{inspect(value)}"}}
            end

          _ ->
            {:ok, %{"text" => Jason.encode!(full, pretty: true)}}
        end

      :error ->
        {:error,
         %{"type" => "actor_not_found", "message" => "no actor #{actor_id}"}}
    end
  end

  def execute(_),
    do:
      {:error,
       %{
         "type" => "invalid_args",
         "message" => "actors_inspect requires args.actor_id"
       }}

  defp build_full(snap, actor_id) do
    base = %{
      "actor_id" => snap.actor_id,
      "actor_type" => snap.actor_type,
      "handler_module" => snap.handler_module,
      "paused" => snap.paused,
      "state" => stringify_keys(snap.state)
    }

    case Esr.Resource.AdapterSocket.Registry.lookup(actor_id_strip_prefix(actor_id)) do
      {:ok, row} ->
        Map.merge(base, %{
          "chat_ids" => row.chat_ids,
          "default_chat_id" => List.first(row.chat_ids) || ""
        })

      :error ->
        base
    end
  end

  defp actor_id_strip_prefix(actor_id) do
    case String.split(actor_id, ":", parts: 2) do
      [_prefix, suffix] -> suffix
      _ -> actor_id
    end
  end

  defp stringify_keys(map) when is_map(map) do
    for {k, v} <- map, into: %{} do
      {to_string(k), stringify_keys(v)}
    end
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp get_in_nested(value, []), do: value
  defp get_in_nested(map, [head | tail]) when is_map(map), do: get_in_nested(Map.get(map, head), tail)
  defp get_in_nested(_, _), do: nil
end
