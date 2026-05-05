defmodule Esr.Commands.Deadletter.List do
  @moduledoc """
  `deadletter_list` slash / admin-queue command — read-only listing
  of `Esr.Resource.DeadLetter.Queue` (envelopes that couldn't be
  routed to a target peer).

  Migrated from `EsrWeb.CliChannel.dispatch("cli:deadletter/list", ...)`
  per `docs/notes/2026-05-05-cli-channel-migration.md`. Same body,
  same data shape — just on the slash registry path now.
  """

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()}

  @spec execute(map()) :: result()
  def execute(_cmd) do
    entries =
      Esr.Resource.DeadLetter.Queue
      |> Esr.Resource.DeadLetter.Queue.list()
      |> Enum.map(&serialise/1)

    body =
      case entries do
        [] -> "no dead-letter entries"
        _ -> Jason.encode!(entries, pretty: true)
      end

    {:ok, %{"text" => body}}
  end

  defp serialise(%Esr.Resource.DeadLetter.Queue.Entry{} = entry) do
    entry
    |> Map.from_struct()
    |> Map.update(:dead_at, nil, fn dt -> if is_nil(dt), do: nil, else: DateTime.to_iso8601(dt) end)
  end

  defp serialise(other), do: %{"raw" => inspect(other)}
end
