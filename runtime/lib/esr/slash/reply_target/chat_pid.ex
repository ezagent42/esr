defmodule Esr.Slash.ReplyTarget.ChatPid do
  @moduledoc """
  ReplyTarget impl that delivers via `send(pid, {:reply, text, ref})`.

  Used by the chat-inbound path: FCP (FeishuChatProxy) registers a
  pending entry keyed by `ref`, then SlashHandler eventually emits
  `{:reply, text, ref}` which FCP turns into a Feishu outbound message.

  Backwards-compat: `Esr.Slash.ReplyTarget.normalize/1` maps a bare pid
  passed to `SlashHandler.dispatch/2` into `{ChatPid, pid}`, so legacy
  callers keep working unchanged.
  """

  @behaviour Esr.Slash.ReplyTarget

  alias Esr.Slash.ReplyTarget

  @impl ReplyTarget
  def respond(pid, {:text, text}, ref) when is_pid(pid) do
    send(pid, {:reply, text, ref})
    :ok
  end

  def respond(pid, result, ref) when is_pid(pid) do
    send(pid, {:reply, format_result(result), ref})
    :ok
  end

  # ----------------------------------------------------------------
  # Result rendering — moved here from Esr.Entity.SlashHandler so
  # SlashHandler stops carrying chat-specific rendering. The impl is
  # the right home for medium-specific text.
  # ----------------------------------------------------------------

  # PR-21j: session_list workspace-scoped result.
  @doc false
  def format_result({:ok, %{"workspace" => ws, "sessions" => sessions}})
      when is_list(sessions) do
    if sessions == [] do
      "workspace #{ws}: no live sessions"
    else
      lines =
        sessions
        |> Enum.map(fn %{"name" => n, "session_id" => sid} -> "  • #{n} (sid=#{sid})" end)
        |> Enum.join("\n")

      "workspace #{ws} sessions (#{length(sessions)}):\n#{lines}"
    end
  end

  # PR-21k: workspace_new result.
  def format_result({:ok, %{"name" => name, "owner" => owner, "root" => root, "chats" => chats}})
      when is_list(chats) do
    chat_summary =
      case chats do
        [] -> "(no chat bindings)"
        list -> "#{length(list)} chat(s) bound"
      end

    "workspace #{name} created (owner=#{owner}, root=#{root}, #{chat_summary}). " <>
      "Now: /new-session #{name} name=<…> cwd=<…> worktree=<…>"
  end

  # PR-21j: workspace_info result.
  def format_result({:ok, %{"name" => name, "owner" => owner, "root" => root} = ws}) do
    chats =
      (Map.get(ws, "chats") || [])
      |> Enum.map(fn c ->
        "  • #{Map.get(c, "chat_id", "?")} @ #{Map.get(c, "app_id", "?")}"
      end)
      |> case do
        [] -> "  (no chat bindings)"
        list -> Enum.join(list, "\n")
      end

    role = Map.get(ws, "role", "-")
    metadata_keys = (Map.get(ws, "metadata") || %{}) |> Map.keys() |> Enum.join(", ")

    """
    workspace #{name}:
      owner: #{owner || "-"}
      root:  #{root || "-"}
      role:  #{role}
      chats:
    #{chats}
      metadata keys: #{metadata_keys}
    """
    |> String.trim()
  end

  def format_result({:ok, %{"branches" => b}}) when is_list(b),
    do: "sessions: " <> Enum.join(b, ", ")

  def format_result({:ok, %{"session_id" => sid}}),
    do: "session started: #{sid}"

  # PR-21λ 2026-05-01: command modules that produce free-form display
  # text (Help, Whoami, Doctor, Agent.List) all return
  # `{:ok, %{"text" => "..."}}`. Render the text directly.
  def format_result({:ok, %{"text" => text}}) when is_binary(text), do: text

  def format_result({:ok, %{} = m}), do: "ok: " <> inspect(m)

  # P3-8: Session.New emits string "missing_capabilities" (not atom).
  def format_result({:error, %{"type" => "missing_capabilities", "caps" => caps}}),
    do: "error: missing caps — " <> Enum.join(caps, ", ")

  def format_result({:error, %{"type" => t}}) when is_binary(t),
    do: "error: " <> t

  def format_result(other), do: "result: " <> inspect(other)
end
