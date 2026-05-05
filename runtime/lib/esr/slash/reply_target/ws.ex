defmodule Esr.Slash.ReplyTarget.WS do
  @moduledoc """
  ReplyTarget impl that pushes the rendered reply as a JSON frame on a
  Phoenix.Channel socket.

  **Stub in PR-2.2.** The full implementation lands in PR-2.8 (REPL),
  which is the first consumer. Until then, returns `{:error,
  :not_implemented}`.

  ## Target shape (provisional, pinned in PR-2.8)

      %{topic: String.t(), event: String.t()}
      | {pid :: pid(), topic :: String.t()}

  The first form broadcasts via `EsrWeb.Endpoint.broadcast!/3`; the
  second targets a specific socket (e.g. an interactive REPL session).
  """

  @behaviour Esr.Slash.ReplyTarget

  require Logger

  @impl Esr.Slash.ReplyTarget
  def respond(target, _result, _ref) do
    Logger.warning(
      "Esr.Slash.ReplyTarget.WS.respond/3: stub — implemented in PR-2.8; " <>
        "target=#{inspect(target)}"
    )

    {:error, :not_implemented}
  end
end
