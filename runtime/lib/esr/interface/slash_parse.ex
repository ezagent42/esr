defmodule Esr.Interface.SlashParse do
  @moduledoc """
  SlashParse contract per session.md §三 AdminSession + §五 Handler:

  > SlashCommandHandler: `use Handler` + 加 `SlashParseInterface`.
  > 处理 user-facing slash 文本，输出 (kind, args).

  Current implementer (post-R11): `Esr.Entity.SlashHandler` does the
  parse work but its public API is `parse/1` returning a richer tuple
  shape. @behaviour adoption deferred until API normalization aligns
  shapes.

  See session.md §七 (SlashParseInterface).
  """

  @doc """
  Parse a slash-command string (e.g. `\"/new-session foo\"`) into a
  `(kind, args)` tuple where `kind` is the canonical command kind
  (e.g. `\"session_new\"`) and `args` is a map of extracted parameters.
  """
  @callback parse(input :: String.t()) ::
              {:ok, kind :: String.t(), args :: map()} | {:error, term()}
end
