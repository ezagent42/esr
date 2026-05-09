defmodule Esr.Commands.Deadletter.Flush do
  @moduledoc """
  `deadletter_flush` slash / admin-queue command — clear
  `Esr.Resource.DeadLetter.Queue`. Returns the count of entries
  cleared in the result text.

  Migrated from `EsrWeb.CliChannel.dispatch("cli:deadletter/flush", ...)`.
  """

  use Esr.Commands.Meta

  command :deadletter_flush do
    slash         :none
    category      "诊断"
    description   "清空 dead-letter queue（返回清掉的条目数）"
    permission    "runtime.deadletter"
    requires_user_binding      false
    requires_workspace_binding false
  end

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()}

  @spec execute(map()) :: result()
  def execute(_cmd) do
    flushed = length(Esr.Resource.DeadLetter.Queue.list(Esr.Resource.DeadLetter.Queue))
    :ok = Esr.Resource.DeadLetter.Queue.clear(Esr.Resource.DeadLetter.Queue)
    {:ok, %{"text" => "flushed #{flushed} dead-letter entries"}}
  end
end
