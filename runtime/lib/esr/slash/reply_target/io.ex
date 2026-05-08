defmodule Esr.Slash.ReplyTarget.IO do
  @moduledoc """
  ReplyTarget impl that prints the rendered reply to a Process I/O
  device (defaults to `:stdio`).

  Used by the escript one-shot path in PR-2.5/2.6 (`esr exec /<slash>`).
  Also useful in tests (target a `StringIO` device, then read output).

  `target` shape: either `:stdio` (atom shorthand) or a Process I/O
  device pid (e.g. from `StringIO.open!/1`). The atom is resolved at
  delivery time, not registration, so processes can swap stdio safely.
  """

  @behaviour Esr.Slash.ReplyTarget

  alias Esr.Slash.ReplyTarget.ChatPid

  @impl Esr.Slash.ReplyTarget
  def respond(target, {:text, text}, _ref) do
    Elixir.IO.puts(device(target), text)
    :ok
  end

  def respond(target, result, _ref) do
    Elixir.IO.puts(device(target), ChatPid.format_result(result))
    :ok
  end

  defp device(:stdio), do: :stdio
  defp device(pid) when is_pid(pid), do: pid
  defp device(other), do: other
end
