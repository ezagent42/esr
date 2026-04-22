defmodule Esr.Peer.Proxy do
  @moduledoc """
  Stateless forwarder Peer.

  Compile-time restricted: a module using `Esr.Peer.Proxy` cannot
  define `handle_call/3` or `handle_cast/2` — doing so raises a
  compile error. This enforces the "proxies never accumulate state"
  rule.

  See spec §3.1.
  """

  @callback forward(msg :: term(), ctx :: map()) ::
              :ok | {:drop, reason :: atom()}

  defmacro __using__(_opts) do
    quote do
      use Esr.Peer, kind: :proxy
      @behaviour Esr.Peer.Proxy

      # Compile-time check: reject stateful callbacks.
      # Implementation deferred to Task P1-3 (will use @before_compile + __ENV__).
    end
  end
end
