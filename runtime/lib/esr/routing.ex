defmodule Esr.Routing do
  @moduledoc """
  Public façade for the Routing subsystem (spec §6.5).

  The Routing subsystem owns per-principal message dispatch. It:

    * subscribes to the Feishu `msg_received` Phoenix.PubSub topic,
    * parses leading-slash admin commands and forwards them to
      `Esr.Admin.Dispatcher` (via cast + correlation-ref),
    * routes non-command messages to the sender's active branch's
      `esrd_url` per `routing.yaml`, and
    * emits Feishu `reply` directives when a command result comes
      back.

  Task 17 (DI-9) ships the GenServer + Supervisor + parser. Task 18
  will add a FileSystem watcher that reloads `routing.yaml` and
  `branches.yaml` when either file changes on disk.
  """

  @doc "List of supported leading-slash admin command prefixes."
  @spec slash_commands() :: [String.t()]
  def slash_commands do
    [
      "/new-session",
      "/switch-session",
      "/end-session",
      "/sessions",
      "/list-sessions",
      "/reload"
    ]
  end
end
