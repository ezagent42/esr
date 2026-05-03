defmodule Esr.Handler do
  @moduledoc """
  Behaviour for Elixir-side modules that expose runtime-intrinsic
  action handlers (e.g. the MCP tool handlers inside `Esr.Entity.Server`,
  or future Elixir-native handler modules).

  Primary use today: permissions declaration. A module that
  `@behaviour Esr.Handler` may optionally export `permissions/0`
  returning the list of action-name strings it implements. At boot,
  `Esr.Capabilities.Supervisor` iterates all loaded `:esr` modules,
  collects their declared permissions, and registers them into
  `Esr.Permissions.Registry` so `capabilities.yaml` entries can
  reference them by name.

  Python-side handlers declare permissions via the
  `@handler(permissions=[...])` decorator and ship them in the
  `handler_hello` IPC envelope on boot (spec §3.1, §4.1).
  """

  @callback permissions() :: [String.t()]

  @optional_callbacks permissions: 0
end
