defmodule Esr.Plugins.ClaudeCode.Commands.Tui do
  @moduledoc """
  `/claude_code:tui name=<agent>` — claude_code plugin command.

  Resolves agent name → PTY actor id via the chat-current session, then
  delegates to `Esr.Commands.Pty.Attach` to emit the URL. A thin shell
  on top of `/pty:attach` — pays the agent-name lookup cost once so
  operators never have to hold the PTY UUID in their head.

  Lives in the claude_code plugin per spec rev-4 D5 (plugin-scoped
  command registration mechanism). Manifest entry under the plugin's
  `slash_routes:` block. Slash + kind use the canonical
  `claude_code:` / `claude_code_` prefix per manifest validator's
  `validate_slash_keys/2` + `validate_kind_names/3` rules.

  Second real consumer of the rev-3 plugin command registration
  mechanism after feishu_notify / feishu_bind / feishu_unbind —
  validates the mechanism end-to-end for /<plugin>:<verb> slash-callable
  paths (feishu only exercises the internal_kinds path).
  """

  use Esr.Commands.Meta

  command :claude_code_tui do
    slash         "/claude_code:tui"
    category      "Plugins"
    description   "把当前 chat 的 session 内某 cc agent 的 PTY URL 发回（/pty:attach 的薄壳 shortcut）"
    permission    nil
    requires_user_binding      true
    requires_workspace_binding false

    arg :name, required: true, doc: "agent 名"

    error :invalid_args,  "/claude_code:tui requires name=<agent> and chat context"
    error :not_found,     "no agent '%{name}' in chat-current session"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render
  alias Esr.Session.ChatRouting.Registry, as: ChatRouting

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(
        %{
          "submitted_by" => submitter,
          "args" => %{"name" => name, "chat_id" => chat_id, "app_id" => app_id}
        } = cmd
      )
      when is_binary(name) and name != "" and is_binary(chat_id) and chat_id != "" and
             is_binary(app_id) and app_id != "" do
    with {:ok, sid} <- ChatRouting.current_session(chat_id, app_id),
         {:ok, pty_id} <- Esr.Entity.Agent.InstanceRegistry.pty_actor_id_for(sid, name) do
      Esr.Commands.Pty.Attach.execute(%{
        "submitted_by" => submitter,
        "args" => Map.put(cmd["args"], "pty", pty_id)
      })
    else
      :not_found ->
        Render.error(__MODULE__.command_meta(), :not_found, %{name: name})
    end
  end

  def execute(_cmd) do
    Render.error(__MODULE__.command_meta(), :invalid_args)
  end
end
