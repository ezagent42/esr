defmodule Esr.Interface.Routing do
  @moduledoc """
  Routing contract: take an inbound envelope and a context, dispatch to
  the appropriate downstream consumer (Scope, Entity, Handler, etc.).

  Implementers in ESR (post-R4):
    - `Esr.Scope.Router` (dispatches `:create_session_sync`, `:end_session_sync`,
       `:new_chat_thread` control-plane events; data-plane is rejected per Risk E)
    - `Esr.HandlerRouter` (routes handler_call envelopes to Python workers)

  See session.md §七 (RoutingInterface) and `docs/notes/structural-refactor-plan-r4-r11.md` §四-R4.
  """

  @doc "Dispatch `envelope` with `ctx` to the appropriate downstream. `:error` shapes carry diagnostic info."
  @callback dispatch(envelope :: map(), ctx :: map()) :: :ok | {:ok, term()} | {:error, term()}
end
