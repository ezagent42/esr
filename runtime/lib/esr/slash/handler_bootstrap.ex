defmodule Esr.Slash.HandlerBootstrap do
  @moduledoc """
  One-shot supervision-tree child whose `init/1` calls
  `Esr.Scope.Admin.bootstrap_slash_handler/0` and returns `:ignore`,
  so the supervisor doesn't track a long-lived process — but it DOES
  block on the bootstrap completing before starting the next child.

  Why a child and not a post-start hook in `Esr.Application.start/2`:
  the post-start hook runs AFTER the children list finishes booting,
  but `Esr.Slash.QueueWatcher` (a child of
  `Esr.Slash.Supervisor`) wants to dispatch any pre-existing
  `pending/*.yaml` orphans through SlashHandler at boot. If the
  bootstrap is post-start, SlashHandler isn't registered when those
  dispatches fire and they're dropped with "boot incomplete".

  By making the bootstrap an explicit child placed BEFORE
  `Esr.Slash.Supervisor`, supervision-tree ordering guarantees the
  ready state is in place when downstream children start.

  PR-2.3b-2 introduced this module along with the deletion of
  `Esr.Admin.Dispatcher`.
  """

  use GenServer

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok)
  end

  @impl true
  def init(:ok) do
    case Esr.Scope.Admin.bootstrap_slash_handler() do
      :ok ->
        :ignore

      {:error, reason} ->
        require Logger

        Logger.warning(
          "slash_handler_bootstrap: failed: #{inspect(reason)}; " <>
            "slash commands unavailable until restart"
        )

        :ignore
    end
  end
end
