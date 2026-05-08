defmodule Esr.Commands.Actors.Tree do
  @moduledoc """
  `actors_tree` slash / admin-queue command — group every live actor
  under its owning Scope (session_id) and render as an indented tree.

  Pre-PR-3.5-followup the cli_channel handler returned
  `%{topologies: [], error: "topology module removed"}` — a stale
  P3-13 stub. This module is the **real implementation**: pulls
  `Esr.Entity.Registry.list_all/0`, parses session_id from the
  actor_id naming convention (`thread:<sid>`,
  `feishu_app_adapter_<id>`, etc.), and prints a tree.

  Per docs/notes/2026-05-05-cli-channel-migration.md.
  """

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()}

  @spec execute(map()) :: result()
  def execute(_cmd) do
    actors = Esr.Entity.Registry.list_all()

    grouped =
      actors
      |> Enum.group_by(&scope_key/1)
      |> Enum.sort_by(fn {scope, _} -> scope_sort_key(scope) end)

    body =
      grouped
      |> Enum.map_join("\n", fn {scope, rows} -> render_group(scope, rows) end)

    body = if body == "", do: "no actors live", else: body
    {:ok, %{"text" => body}}
  end

  # Parse the actor_id naming convention into a "scope" tag the tree
  # groups by. Convention as of 2026-05-05:
  # - `thread:<sid>`               → {:session, sid}
  # - `cc_<sid>` / `cc_proxy_<sid>` → {:session, sid}
  # - `feishu_app_adapter_<id>`    → :admin
  # - `feishu_chat_proxy_<...>`    → :admin
  # - anything else                → :unscoped
  defp scope_key({actor_id, _pid}) when is_binary(actor_id) do
    cond do
      String.starts_with?(actor_id, "thread:") ->
        {:session, String.replace_prefix(actor_id, "thread:", "")}

      match = Regex.run(~r/^cc(?:_proxy)?_(.+)$/, actor_id) ->
        [_, sid] = match
        {:session, sid}

      String.starts_with?(actor_id, "feishu_app_adapter_") or
          String.starts_with?(actor_id, "feishu_chat_proxy_") ->
        :admin

      true ->
        :unscoped
    end
  end

  defp scope_sort_key(:admin), do: {0, ""}
  defp scope_sort_key({:session, sid}), do: {1, sid}
  defp scope_sort_key(:unscoped), do: {2, ""}

  defp render_group(scope, rows) do
    header =
      case scope do
        :admin -> "admin scope:"
        {:session, sid} -> "session #{sid}:"
        :unscoped -> "unscoped:"
      end

    lines =
      rows
      |> Enum.sort_by(fn {actor_id, _pid} -> actor_id end)
      |> Enum.map_join("\n", fn {actor_id, pid} ->
        pid_str = pid |> inspect() |> String.replace_prefix("#PID", "")
        "  #{actor_id}  pid=#{pid_str}"
      end)

    header <> "\n" <> lines
  end
end
