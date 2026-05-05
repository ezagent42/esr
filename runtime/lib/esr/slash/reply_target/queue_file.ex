defmodule Esr.Slash.ReplyTarget.QueueFile do
  @moduledoc """
  ReplyTarget impl that persists the reply as a yaml file in
  `~/.esrd/<env>/admin_queue/<dest_dir>/<id>.yaml` via
  `Esr.Slash.QueueResult.finish/3`.

  ## Target shape

      %{id: String.t(), command: map()}

  - `id` — the queue file id (basename without `.yaml` extension).
  - `command` — the original command doc parsed from
    `pending/<id>.yaml`. Used so the destination doc carries the
    full submission record (id, kind, args, submitted_by) plus the
    `result` field merged from the response.

  ## Behaviour

  Looks at the response's success/error shape to pick the destination
  directory:
    - `{:ok, _}`       → `completed/`
    - anything else    → `failed/`
    - `{:text, str}`   → `failed/` with the synthesized error doc
                         (covers timeout / unknown-command / validation
                         errors that don't carry a structured result)

  Calls `QueueResult.finish/3` which atomically moves
  `processing/<id>.yaml` → `<dest_dir>/<id>.yaml` and writes the
  merged document on top, with redaction.

  PR-2.3b-1 promoted this from stub to real impl. The Watcher pivot
  to use it (and the corresponding Dispatcher deletion) lands in
  PR-2.3b-2 to keep the test fallout small per change.
  """

  @behaviour Esr.Slash.ReplyTarget

  alias Esr.Slash.QueueResult

  @impl Esr.Slash.ReplyTarget
  def respond(%{id: id, command: command}, response, _ref)
      when is_binary(id) and is_map(command) do
    {dest_dir, result_map} = render(response)

    doc =
      command
      |> Map.put("result", result_map)

    QueueResult.finish(id, dest_dir, doc)
  end

  defp render({:ok, %{} = m}), do: {"completed", Map.merge(%{"ok" => true}, stringify(m))}
  defp render({:ok, other}), do: {"completed", %{"ok" => true, "value" => inspect(other)}}

  defp render({:error, %{} = m}), do: {"failed", Map.merge(%{"ok" => false}, stringify(m))}
  defp render({:error, other}), do: {"failed", %{"ok" => false, "error" => inspect(other)}}

  defp render({:text, text}) when is_binary(text),
    do: {"failed", %{"ok" => false, "error" => text}}

  defp render(other), do: {"failed", %{"ok" => false, "error" => inspect(other)}}

  defp stringify(map) when is_map(map) do
    for {k, v} <- map, into: %{} do
      {to_string(k), v}
    end
  end
end
