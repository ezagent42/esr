defmodule Esr.Commands.Actors.List do
  @moduledoc """
  `/actors list` slash command — enumerate every registered Entity peer.

  Mirrors the historic Python `esr actors list` (which queried via the
  `cli:actors/list` Phoenix channel). Reading via the slash dispatch
  path lets the Elixir-native escript reach the same data without
  opening a WebSocket.

  Output text is one line per peer in the form `<actor_id>  pid=<0.N.M>`,
  matching the Python CLI's `actors_list` formatter so dual-rail e2e
  assertions (`awk '/^thread:/'` etc.) work uniformly across rails.

  Phase B-1 of the Phase 3/4 finish (2026-05-05). See
  `docs/notes/2026-05-05-cli-dual-rail.md`.
  """

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()}

  @spec execute(map()) :: result()
  def execute(_cmd) do
    text =
      Esr.Entity.Registry.list_all()
      |> Enum.sort_by(fn {actor_id, _pid} -> actor_id end)
      |> Enum.map_join("\n", &format_row/1)

    body = if text == "", do: "no actors live", else: text
    {:ok, %{"text" => body}}
  end

  defp format_row({actor_id, pid}) do
    pid_str = pid |> inspect() |> String.replace_prefix("#PID", "")
    "#{actor_id}  pid=#{pid_str}"
  end
end
