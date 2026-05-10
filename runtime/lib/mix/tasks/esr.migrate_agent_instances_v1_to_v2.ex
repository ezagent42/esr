defmodule Mix.Tasks.Esr.MigrateAgentInstancesV1ToV2 do
  @moduledoc """
  One-shot migration: convert v1 session.json files (with embedded
  `agents:[]` array) to the Phase 7 v2 layout where each agent
  instance lives in `sessions/<sid>/agents/<instance_uuid>.json` and
  session.json carries `agent_ids: [<uuid>...]`.

  Idempotent: if `session.json` already has `schema_version: 2`, the
  walk skips it.

  ## Usage

      mix esr.migrate_agent_instances_v1_to_v2 [--home <path>]

  Without `--home`, the task walks `~/.esrd/<inst>/sessions/` (where
  `<inst>` is the active `ESR_INSTANCE` or `default`). Pass `--home`
  to override the per-instance runtime home (used by tests).

  ## Boot-time hook

  `Esr.Application.start/2` invokes
  `Esr.Migrations.AgentInstancesV1ToV2.run_if_needed/0` so a stale v1
  install gets migrated on the next esrd boot — operators don't need
  to remember to invoke this manually.

  Phase 7 (2026-05-10).
  """

  use Mix.Task

  @shortdoc "Migrate session.json v1 → v2: split agents into per-instance files"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [home: :string])
    home = Keyword.get(opts, :home, Esr.Paths.runtime_home())

    {:ok, %{migrated: m, skipped: s}} = Esr.Migrations.AgentInstancesV1ToV2.run(home)
    Mix.shell().info("agent_instances v1→v2: migrated=#{m} skipped=#{s} (home=#{home})")
  end
end
