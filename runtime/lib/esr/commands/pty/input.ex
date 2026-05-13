defmodule Esr.Commands.Pty.Input do
  @moduledoc """
  `/pty:input name=<agent> text=<...>` — write arbitrary text to the
  named agent's PTY stdin (no key translation, no trailing `\\r`).

  Operator-driven complement to `/pty:key`. Pair with `/pty:key enter`
  to submit. Distinct from CC's MCP `reply`/`send_input` tools which
  travel through the channel bridge — this writes bytes directly to
  the PTY pipe.

  Spec: `docs/superpowers/specs/2026-05-13-cc-channel-stdio-bridge-design.md` §6.5.
  """

  use Esr.Commands.Meta

  command :pty_input do
    slash         "/pty:input"
    category      "PTY"
    description   "把任意文本写入指定 agent 的 PTY stdin（不附加 \\r；如需提交配合 /pty:key enter）"
    permission    nil
    requires_user_binding      true
    requires_workspace_binding false

    arg :name, required: true, doc: "agent name (resolved to PTY actor via chat-current session)"
    arg :text, required: true, doc: "free-form text written to PTY stdin literally"

    error :no_session_target,
          "no chat-current session; bind via /session:bind-chat first"
    error :not_found,
          "no agent '%{name}' in chat-current session"
    error :invalid_args, "/pty:input requires name=<agent> and text=<...>"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render
  alias Esr.Session.ChatRouting.Registry, as: ChatRouting

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{
        "args" => %{
          "chat_id" => chat_id,
          "app_id" => app_id,
          "name" => name,
          "text" => text
        }
      })
      when is_binary(chat_id) and chat_id != "" and is_binary(app_id) and app_id != "" and
             is_binary(name) and name != "" and is_binary(text) and text != "" do
    case ChatRouting.current_session(chat_id, app_id) do
      {:ok, sid} ->
        case Esr.Uri.Compat.pty_actor_id_for(sid, name) do
          {:ok, pty_actor_id} ->
            :ok = Esr.Entity.PtyProcess.write(pty_actor_id, text)
            {:ok, %{"text" => "🎹 wrote #{byte_size(text)} byte(s) to PTY"}}

          :not_found ->
            Render.error(__MODULE__.command_meta(), :not_found, %{name: name})
        end

      :not_found ->
        Render.error(__MODULE__.command_meta(), :no_session_target)
    end
  end

  def execute(_), do: Render.error(__MODULE__.command_meta(), :invalid_args)
end
