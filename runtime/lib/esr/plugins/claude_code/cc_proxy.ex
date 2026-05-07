defmodule Esr.Entity.CCProxy do
  @moduledoc """
  Stateless Peer.Proxy between the upstream chat proxy and CCProcess
  (downstream) within the same Session. In PR-3 this is a pure forwarder;
  the `@required_cap` hook is the first enforcement point for any
  rate-limit / throttle policy between channels and CC agents.

  ctx shape (computed at session-spawn time by P3-4 Scope.Router; in
  tests/PR-3-interim injected manually by callers):
    %{
      principal_id:    binary,   # who owns the session
      cc_process_pid:  pid       # local CCProcess target (same Session)
    }

  The `@required_cap "peer_proxy:cc/forward"` attribute (canonical
  `prefix:name/perm` form, landed in P3-8) triggers the `Esr.Entity.Proxy`
  macro's capability-check wrapper around `forward/2`: principal_id is
  looked up via `Esr.Resource.Capability.has?/2`, and on denial the call
  short-circuits with `{:drop, :cap_denied}` before the user body runs.

  Spec §3.6, §4.1 CCProxy card.
  """

  @behaviour Esr.Role.Pipeline
  use Esr.Entity.Proxy
  @required_cap "peer_proxy:cc/forward"

  # M-1.5: compile-time role constant. CCProxy is stateless (no
  # `init/1` / no GenServer state), so it does not call
  # `register_attrs/2` itself — the constant is exposed here so callers
  # that want to filter `Esr.ActorQuery.list_by_role/2` results, or
  # that build per-role topology snapshots, can name this proxy
  # symbolically without grepping for a string.
  @role :cc_proxy

  @impl Esr.Entity.Proxy
  def forward(msg, %{cc_process_pid: target} = _ctx) when is_pid(target) do
    if Process.alive?(target) do
      send(target, msg)
      :ok
    else
      {:drop, :target_unavailable}
    end
  end

  def forward(_msg, _ctx), do: {:drop, :invalid_ctx}
end
