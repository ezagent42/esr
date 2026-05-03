defmodule Esr.Entities.FeishuAppProxy do
  @moduledoc """
  Per-Session Peer.Proxy: outbound door from the Session to the Scope.Admin's
  FeishuAppAdapter_<app_id>. Carries a capability check on forward — declared
  via @required_cap so the PR-1 Peer.Proxy macro extension (P2-4) wraps
  forward/2 with Esr.Resource.Capability.has?/2.

  ctx shape (computed once at session-spawn time in PR-3's Scope.Router;
  in PR-2 injected manually by callers/tests):
    %{
      principal_id:  binary,   # who owns the session
      target_pid:    pid,      # Scope.Admin.FeishuAppAdapter_<app_id>
      app_id:        binary
    }

  Spec §3.6, §4.1 FeishuAppProxy card.
  """

  @behaviour Esr.Role.Pipeline
  use Esr.Entity.Proxy
  @required_cap "peer_proxy:feishu/forward"

  @impl Esr.Entity.Proxy
  def forward(msg, %{target_pid: target} = _ctx) when is_pid(target) do
    if Process.alive?(target) do
      send(target, msg)
      :ok
    else
      {:drop, :target_unavailable}
    end
  end

  def forward(_msg, _ctx), do: {:drop, :invalid_ctx}
end
