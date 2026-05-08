defmodule Esr.Interface.Boot do
  @moduledoc """
  Boot contract per session.md §二 DaemonSession Context:

  > 实现 BootInterface — 启动 / 关闭 / 健康检查

  The Daemon Scope (≡ `Esr.Application` per concepts.md §🔧-5)
  implements this contract via OTP's standard `Application` callbacks
  (`start/2`, `stop/1`). This Interface re-frames those in metamodel
  terms.

  Current implementer: `Esr.Application` could declare
  `@behaviour Esr.Interface.Boot` — but its `start/2` and `stop/1` are
  required by OTP's `Application` behaviour with specific arities
  (start/2 takes `start_type` + `start_args`, returning `{:ok, pid}`).
  This Interface keeps the metamodel-level contract (no args, returns
  :ok) — a thin wrapper would bridge.

  Adopted aspirationally; @behaviour adoption deferred to API
  normalization sweep.

  See session.md §七 (BootInterface).
  """

  @doc "Boot the system. Called once at OTP application start."
  @callback start() :: :ok | {:error, term()}

  @doc "Shut down the system. Called once at OTP application stop."
  @callback stop() :: :ok

  @doc "Health check — returns :ok if system is healthy, otherwise diagnostic."
  @callback health() :: :ok | {:error, term()}
end
