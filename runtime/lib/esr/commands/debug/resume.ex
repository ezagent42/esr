defmodule Esr.Commands.Debug.Resume do
  @moduledoc """
  `debug_resume` slash / admin-queue command — counterpart to
  `Esr.Commands.Debug.Pause`. Releases the `:sys.suspend` hold on
  `actor_id`'s GenServer.

  Migrated from `EsrWeb.CliChannel.dispatch("cli:debug/resume", ...)`.
  """

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"actor_id" => actor_id}}) when is_binary(actor_id) and actor_id != "" do
    case Esr.Entity.Registry.lookup(actor_id) do
      {:ok, _pid} ->
        :ok = Esr.Entity.Server.resume(actor_id)
        snap = Esr.Entity.Server.describe(actor_id)
        {:ok, %{"text" => "resumed #{actor_id} (paused=#{snap.paused})"}}

      :error ->
        {:error, %{"type" => "actor_not_found", "message" => "no actor #{actor_id}"}}
    end
  end

  def execute(_),
    do:
      {:error,
       %{"type" => "invalid_args", "message" => "debug_resume requires args.actor_id"}}
end
