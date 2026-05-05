defmodule Esr.Commands.User.List do
  @moduledoc """
  `user_list` slash / admin-queue command — print every registered esr
  user with their bound feishu_ids. Mirrors Python `esr user list`.

  Reads `Esr.Entity.User.Registry` directly (in-memory ETS).

  Phase B-3 of the Phase 3/4 finish (2026-05-05).
  """

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()}

  @spec execute(map()) :: result()
  def execute(_cmd) do
    text =
      Esr.Entity.User.Registry.list()
      |> Enum.sort_by(& &1.username)
      |> Enum.map_join("\n", &format_row/1)

    body = if text == "", do: "no users registered", else: text
    {:ok, %{"text" => body}}
  end

  defp format_row(%{username: name, feishu_ids: ids}) do
    case ids do
      [] -> "#{name}  (unbound)"
      _ -> "#{name}  feishu_ids=#{Enum.join(ids, ",")}"
    end
  end
end
