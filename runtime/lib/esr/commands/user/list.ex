defmodule Esr.Commands.User.List do
  @moduledoc """
  `user_list` slash / admin-queue command — print every registered esr
  user with their bound feishu_ids. Mirrors Python `esr user list`.

  Reads the URI store directly via `Esr.Uri.Compat.list_users/0`
  (PR-1: User.Registry deleted, replaced by `:esr_uri_store`).

  Phase B-3 of the Phase 3/4 finish (2026-05-05).
  """

  use Esr.Commands.Meta

  command :user_list do
    slash         :none
    category      "Users"
    description   "列出所有已注册的 esr user 及其 feishu_id 绑定"
    permission    nil
    requires_user_binding      false
    requires_workspace_binding false
  end

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()}

  @spec execute(map()) :: result()
  def execute(_cmd) do
    text =
      Esr.Uri.Compat.list_users()
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
