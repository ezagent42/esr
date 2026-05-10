defmodule Esr.Channel do
  @moduledoc """
  Per-session transport peer abstraction. Each Channel impl is a
  GenServer-shaped module shipped by a plugin. Impls live under
  `Esr.Plugins.<plugin>.Channels.<name>`; behaviour requirements
  apply to every impl.

  Channels are supervised under per-session AgentInstanceSupervisor
  with `:one_for_all` strategy (M-2.6). Crash → siblings restart in
  lockstep → re-register their pids in the per-session Registry.

  ## Adapter pattern

  The `pid` arg in `dispatch/2` and `subscribe/3` is the Channel's
  GenServer lifecycle peer, NOT the wire-level transport. Concrete
  impls may internally route via Phoenix.PubSub broadcast, HTTP POST,
  WebSocket frame, etc. The Channel pid is the addressable lifecycle
  handle; the wire shape is the impl's choice.

  History: 2026-05-10 spec `2026-05-10-session-template-and-channel.md`
  Phase 1 ships the behaviour + registry; Phase 2 lands the first
  impl (claude_code MCP HTTP).
  """

  @callback start_link(opts :: keyword) :: {:ok, pid} | {:error, term}
  @callback dispatch(pid, msg :: term) :: :ok | {:error, term}
  @callback subscribe(pid, listener_pid :: pid, topic :: term) :: :ok
  @callback config_schema() :: map
  @optional_callbacks config_schema: 0
end
