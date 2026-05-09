defmodule Esr.Commands.Pty.Key do
  @moduledoc """
  `/pty:key <keyspec> [<keyspec> …]` — send special keystrokes to the
  chat-current session's PTY.

  Phase 6 colon-namespace cutover: `/key` renamed to `/pty:key`.
  Delegates directly to `Esr.Commands.Key` which owns the full
  implementation (key translation, chat-scope lookup, PTY write).
  """

  use Esr.Commands.Meta

  command :pty_key do
    slash         "/pty:key"
    category      "PTY"
    description   "把特殊键盘输入（up/down/enter/esc/tab/c-X 等）发到 chat-current session 的 PTY"
    permission    nil
    requires_user_binding      false
    requires_workspace_binding false

    arg :keys, required: true, doc: "key spec(s); 例 up enter c-c esc"
  end

  @behaviour Esr.Role.Control

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  defdelegate execute(cmd), to: Esr.Commands.Key
end
