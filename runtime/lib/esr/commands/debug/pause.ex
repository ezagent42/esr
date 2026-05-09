defmodule Esr.Commands.Debug.Pause do
  @moduledoc """
  `debug_pause` slash / admin-queue command — suspend an actor's
  GenServer message processing via `:sys.suspend`. Used to debug
  stuck pids without killing them.

  Migrated from `EsrWeb.CliChannel.dispatch("cli:debug/pause", ...)`.
  """

  use Esr.Commands.Meta

  command :debug_pause do
    slash         :none
    category      "诊断"
    description   "用 :sys.suspend 暂停指定 actor 的 GenServer 消息处理"
    permission    "runtime.debug"
    requires_user_binding      false
    requires_workspace_binding false

    arg :actor_id, required: true, doc: "目标 actor id"

    error :invalid_args,     "debug_pause requires args.actor_id"
    error :actor_not_found,  "no actor %{actor_id}"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"actor_id" => actor_id}}) when is_binary(actor_id) and actor_id != "" do
    case Esr.Entity.Registry.lookup(actor_id) do
      {:ok, _pid} ->
        :ok = Esr.Entity.Server.pause(actor_id)
        snap = Esr.Entity.Server.describe(actor_id)
        {:ok, %{"text" => "paused #{actor_id} (paused=#{snap.paused})"}}

      :error ->
        Render.error(__MODULE__.command_meta(), :actor_not_found, %{actor_id: actor_id})
    end
  end

  def execute(_),
    do: Render.error(__MODULE__.command_meta(), :invalid_args)
end
