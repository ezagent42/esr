defmodule Esr.Commands.Debug.Resume do
  @moduledoc """
  `debug_resume` slash / admin-queue command — counterpart to
  `Esr.Commands.Debug.Pause`. Releases the `:sys.suspend` hold on
  `actor_id`'s GenServer.

  Migrated from `EsrWeb.CliChannel.dispatch("cli:debug/resume", ...)`.
  """

  use Esr.Commands.Meta

  command :debug_resume do
    slash         :none
    category      "诊断"
    description   "解除 :sys.suspend 暂停（debug_pause 的反向操作）"
    permission    "runtime.debug"
    requires_user_binding      false
    requires_workspace_binding false

    arg :actor_id, required: true, doc: "目标 actor id"

    error :invalid_args,     "debug_resume requires args.actor_id"
    error :actor_not_found,  "no actor %{actor_id}"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"actor_id" => actor_id}}) when is_binary(actor_id) and actor_id != "" do
    case Esr.Entity.Registry.lookup(actor_id) do
      {:ok, _pid} ->
        :ok = Esr.Entity.Server.resume(actor_id)
        snap = Esr.Entity.Server.describe(actor_id)
        {:ok, %{"text" => "resumed #{actor_id} (paused=#{snap.paused})"}}

      :error ->
        Render.error(__MODULE__.command_meta(), :actor_not_found, %{actor_id: actor_id})
    end
  end

  def execute(_),
    do: Render.error(__MODULE__.command_meta(), :invalid_args)
end
