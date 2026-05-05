defmodule Esr.Slash.ReplyTarget.QueueFile do
  @moduledoc """
  ReplyTarget impl that persists the reply as a yaml file in
  `~/.esrd/<env>/admin_queue/completed/<id>.yaml`.

  **Stub in PR-2.2.** The full implementation lands in PR-2.3a/b
  alongside `Esr.Slash.QueueResult`, which owns the secret-redaction
  rules and the pending → processing → completed/failed file state
  machine. Reason for stubbing now: PR-2.2 establishes the abstraction
  shape; PR-2.3a builds the modules behind it.

  Until PR-2.3a lands, every `respond/3` here logs a warning and
  returns `{:error, :not_implemented}`. SlashHandler treats that as a
  best-effort delivery failure (logs and moves on).

  ## Target shape (provisional)

      %{queue_id: String.t(), env: String.t(), submitted_by: String.t()}

  PR-2.3a will pin this down once `QueueResult.finish/2` is in place.
  """

  @behaviour Esr.Slash.ReplyTarget

  require Logger

  @impl Esr.Slash.ReplyTarget
  def respond(target, _result, _ref) do
    Logger.warning(
      "Esr.Slash.ReplyTarget.QueueFile.respond/3: stub — implemented in PR-2.3a; " <>
        "target=#{inspect(target)}"
    )

    {:error, :not_implemented}
  end
end
