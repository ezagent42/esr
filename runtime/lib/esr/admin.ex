defmodule Esr.Admin do
  @moduledoc """
  Public façade for the Admin subsystem.

  The Admin subsystem is the execution engine for runtime-mutating
  commands submitted either from the CLI (via the file-based command
  queue watched by `Esr.Admin.CommandQueue.Watcher`) or from the
  Feishu slash-command path (via `Esr.Entities.SlashHandler`, the
  session-scoped slash-parser peer introduced in PR-2; the legacy
  `Esr.Routing.SlashHandler` was removed in PR-3 P3-14).

  This module also declares the subsystem-intrinsic permissions. They
  are registered at boot by `Esr.Resource.Permission.Bootstrap` alongside
  handler-declared permissions (see spec §6.2). The `permissions/0`
  callback shape mirrors the `Esr.Handler` behaviour's optional
  `permissions/0` callback so the bootstrap iteration is uniform.
  """

  @doc """
  Subsystem-intrinsic permissions declared by Admin.

  The Dispatcher's `required_permission(kind)` table (spec §6.2) maps
  each admin command kind onto one of these strings. They are returned
  as plain strings (same shape as handler-declared permissions) so the
  Permissions.Bootstrap pass can register them without branching on
  source.
  """
  @spec permissions() :: [String.t()]
  def permissions do
    [
      "notify.send",
      "runtime.reload",
      "adapter.register",
      "session.create",
      "session.switch",
      "session.end",
      "session.list",
      "cap.manage",
      # PR-3 P3-8/P3-9: canonical prefix:name/perm form for the new
      # agent-session lifecycle commands (`session_new` +
      # `session_branch_new` share `session:default/create`; `session_end`
      # + `session_branch_end` share `session:default/end`).
      "session:default/create",
      "session:default/end",
      # PR-21k: workspace.create — creating a workspace from inside
      # Feishu (via /new-workspace slash) writes workspaces.yaml.
      # Bootstrap path: `esr cap grant <esr-user> workspace.create`.
      "workspace.create"
    ]
  end
end
