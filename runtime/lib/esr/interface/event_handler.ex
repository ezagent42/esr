defmodule Esr.Interface.EventHandler do
  @moduledoc """
  EventHandler contract per session.md §五 Handler:

  > 职责：处理特定 actor_type event 的纯函数。接收 event，返回 (new_state, [actions]).
  > 实现的 Interface:
  > - `EventHandlerInterface` — event → (state, [actions])
  > - `PurityInterface` — 编译期检查 import 限制

  Current implementer (post-R11): `Esr.Handler` provides the base
  behaviour today (see `runtime/lib/esr/handler.ex`); a future PR
  may align its callbacks to this Interface and adopt @behaviour.

  See session.md §七 (EventHandlerInterface).
  """

  @doc """
  Pure function: take an event + current state, return new state and
  a list of actions for the runtime to execute. Handlers MUST NOT
  perform side effects directly — actions are the only escape hatch.
  """
  @callback handle_event(event :: map(), state :: term()) ::
              {state :: term(), actions :: [term()]}
end

defmodule Esr.Interface.Purity do
  @moduledoc """
  Purity contract per session.md §五 Handler:

  > Purity 约束：handler 只能 import `esr` SDK + 自己的 package；
  > 不持有跨 invocation 状态。

  This Interface is enforced at compile-time, not at runtime — it's
  a marker for static analysis tools to check that an EventHandler's
  imports stay within the allowed set.

  Current implementer: aspirational. Today's purity check is via
  `mix credo` + ad-hoc review. Future R-batch may add a static
  analyzer that consults this @behaviour to know which modules to
  enforce purity on.

  See session.md §七 (PurityInterface).
  """

  @doc """
  Return the allowlist of import paths this Handler may use. Static
  analyzers use this to enforce purity at compile time. The default
  allowlist is `[\"esr\", <module's own package>]` per the metamodel.
  """
  @callback allowed_imports() :: [String.t()]
end
