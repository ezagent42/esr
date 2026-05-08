defmodule Esr.Admin do
  @moduledoc """
  Public façade for the Admin subsystem.

  The Admin subsystem is the execution engine for runtime-mutating
  commands submitted either from the CLI (via the file-based command
  queue watched by `Esr.Slash.QueueWatcher`) or from the
  Feishu slash-command path (via `Esr.Entity.SlashHandler`, the
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
      # Audit #6 rev-3 (2026-05-08-plugin-command-registration spec §5.5):
      # `notify.send` migrated to feishu plugin as `feishu/notify-send`,
      # declared by runtime/lib/esr/plugins/feishu/manifest.yaml.
      "runtime.reload",
      "adapter.register",
      "session.create",
      "session.switch",
      "session.end",
      "session.list",
      # Phase D (resource-typed grammar rev-3 §4.2): `/session:bind-chat`
      # slash-table coarse pre-gate. The fine-grained per-session cap
      # (`session:<uuid>/attach` or `session:<uuid>/admin`) is checked
      # inside `Esr.Commands.Session.BindChat.execute/1`. Declared here
      # so any ops who want to grant the bare flat cap (e.g. as a
      # blanket pre-gate for dev/admin users) can do so — without a
      # declaration the file_loader rejects it as :unknown_permission.
      "session.attach",
      "cap.manage",
      # PR-3 P3-8/P3-9: canonical prefix:name/perm form for the new
      # agent-session lifecycle commands (`session_new` +
      # `session_branch_new` share `session:default/create`; `session_end`
      # + `session_branch_end` share `session:default/end`).
      #
      # Phase B (resource-typed grammar spec rev-4 §4.2 row 1):
      # `session:default/read` gates `/session:list`. Without a
      # declaration here the cap is un-grantable + the slash unreachable
      # for any non-admin user.
      "session:default/create",
      "session:default/end",
      "session:default/read",
      # Phase C (resource-typed grammar spec rev-4 §4.2 rows 6-9):
      # `session:default/spawn` gates the per-agent slash family
      # (/agent:add, /agent:remove, /agent:set-primary, /agent:rename).
      # Without a declaration here the cap is un-grantable + the slashes
      # unreachable for any non-admin user (parallel to `session:default/read`
      # in Phase B).
      "session:default/spawn",
      # PR-21k: workspace.create — creating a workspace from inside
      # Feishu (via /new-workspace slash) writes workspaces.yaml.
      # Bootstrap path: `esr cap grant <esr-user> workspace.create`.
      "workspace.create"
    ]
  end
end
