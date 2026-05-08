defmodule Esr.Commands.Debug.Pause do
  @moduledoc """
  `debug_pause` slash / admin-queue command — suspend an actor's
  GenServer message processing via `:sys.suspend`. Used to debug
  stuck pids without killing them.

  Migrated from `EsrWeb.CliChannel.dispatch("cli:debug/pause", ...)`.
  """

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"actor_id" => actor_id}}) when is_binary(actor_id) and actor_id != "" do
    case Esr.Entity.Registry.lookup(actor_id) do
      {:ok, _pid} ->
        :ok = Esr.Entity.Server.pause(actor_id)
        snap = Esr.Entity.Server.describe(actor_id)
        {:ok, %{"text" => "paused #{actor_id} (paused=#{snap.paused})"}}

      :error ->
        {:error, %{"type" => "actor_not_found", "message" => "no actor #{actor_id}"}}
    end
  end

  def execute(_),
    do:
      {:error,
       %{"type" => "invalid_args", "message" => "debug_pause requires args.actor_id"}}
end
