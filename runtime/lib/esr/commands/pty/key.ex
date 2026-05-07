defmodule Esr.Commands.Pty.Key do
  @moduledoc """
  `/pty:key <keyspec> [<keyspec> …]` — send special keystrokes to the
  chat-current session's PTY.

  Phase 6 colon-namespace cutover: `/key` renamed to `/pty:key`.
  Delegates directly to `Esr.Commands.Key` which owns the full
  implementation (key translation, chat-scope lookup, PTY write).
  """

  @behaviour Esr.Role.Control

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  defdelegate execute(cmd), to: Esr.Commands.Key
end
