defmodule Esr.Peer.Proxy do
  @moduledoc """
  Stateless forwarder Peer.

  Compile-time restricted: a module using `Esr.Peer.Proxy` cannot
  define `handle_call/3` or `handle_cast/2`. This enforces "proxies
  never accumulate state".

  See spec §3.1.
  """

  @callback forward(msg :: term(), ctx :: map()) ::
              :ok | {:drop, reason :: atom()}

  @forbidden [{:handle_call, 3}, {:handle_cast, 2}]

  defmacro __using__(_opts) do
    quote do
      use Esr.Peer, kind: :proxy
      @behaviour Esr.Peer.Proxy
      @before_compile Esr.Peer.Proxy
    end
  end

  defmacro __before_compile__(env) do
    defined = Module.definitions_in(env.module, :def)

    offenders =
      for fa <- @forbidden, fa in defined, do: fa

    if offenders != [] do
      msg =
        "Esr.Peer.Proxy module #{inspect(env.module)} cannot define stateful callbacks. " <>
          "Found: #{inspect(offenders)}. Use Esr.Peer.Stateful if you need state."

      raise CompileError, description: msg
    end

    :ok
  end
end
