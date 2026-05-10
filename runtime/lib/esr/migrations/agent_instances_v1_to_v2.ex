defmodule Esr.Migrations.AgentInstancesV1ToV2 do
  @moduledoc """
  Phase 7 (2026-05-10) one-shot migration logic.

  Walks `<home>/sessions/` and converts every v1 `session.json` to v2:

    1. For each agent entry in the v1 `agents:[]` array, mints a fresh
       UUID and writes `<home>/sessions/<sid>/agents/<uuid>.json` with
       schema_version=2 (`session_ids: [<sid>]`, single-element).
    2. Rewrites `session.json` with `schema_version: 2`, replacing the
       `agents:[]` array with `agent_ids: [<uuid>...]`.

  Idempotent: any `session.json` already at `schema_version: 2` is
  skipped. Mid-flight crashes are recoverable — the agent files are
  written first, the session.json rewrite is the last step.
  """

  require Logger
  alias Esr.Entity.Agent.{Instance, InstanceJson}

  @doc """
  Run the migration against the given runtime-home path. Returns
  `{:ok, %{migrated: N, skipped: M}}`. Per-file errors are logged
  and counted in `:skipped` — the public contract is total-fail-
  through so a single bad on-disk state can't block esrd boot.
  """
  @spec run(String.t()) :: {:ok, %{migrated: non_neg_integer(), skipped: non_neg_integer()}}
  def run(home) when is_binary(home) do
    sessions_dir = Path.join(home, "sessions")

    if File.exists?(sessions_dir) do
      counts =
        sessions_dir
        |> File.ls!()
        |> Enum.reduce(%{migrated: 0, skipped: 0}, fn entry, acc ->
          path = Path.join([sessions_dir, entry, "session.json"])

          case migrate_one(path) do
            :migrated -> Map.update!(acc, :migrated, &(&1 + 1))
            :skipped -> Map.update!(acc, :skipped, &(&1 + 1))
            :no_session_json -> acc
            {:error, reason} ->
              Logger.warning(
                "agent_instances_v1_to_v2: failed to migrate #{path} reason=#{inspect(reason)}"
              )

              Map.update!(acc, :skipped, &(&1 + 1))
          end
        end)

      {:ok, counts}
    else
      {:ok, %{migrated: 0, skipped: 0}}
    end
  end

  @doc """
  Convenience entry point used by `Esr.Application.start/2`. Migrates
  the active runtime home (`Esr.Paths.runtime_home/0`) when at least
  one v1 session.json is detected. Logs the result. Best-effort —
  errors are logged, never raised.
  """
  @spec run_if_needed() :: :ok
  def run_if_needed do
    home = Esr.Paths.runtime_home()
    sessions_dir = Path.join(home, "sessions")

    if File.exists?(sessions_dir) and v1_present?(sessions_dir) do
      Logger.info("agent_instances_v1_to_v2: v1 session(s) detected; running migration on #{home}")

      {:ok, %{migrated: m, skipped: s}} = run(home)
      Logger.info("agent_instances_v1_to_v2: migrated=#{m} skipped=#{s}")
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp migrate_one(session_json_path) do
    case File.read(session_json_path) do
      {:error, :enoent} ->
        :no_session_json

      {:error, reason} ->
        {:error, {:read_failed, reason}}

      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"schema_version" => 2}} ->
            :skipped

          {:ok, %{"schema_version" => 1} = doc} ->
            do_migrate(session_json_path, doc)

          {:ok, %{"schema_version" => v}} ->
            {:error, {:unknown_schema_version, v}}

          {:ok, _} ->
            {:error, :no_schema_version}

          {:error, reason} ->
            {:error, {:json_decode_failed, reason}}
        end
    end
  end

  defp do_migrate(session_json_path, %{"id" => sid} = doc) when is_binary(sid) do
    agents = Map.get(doc, "agents") || []
    primary = Map.get(doc, "primary_agent")

    session_dir = Path.dirname(session_json_path)
    agents_dir = Path.join(session_dir, "agents")
    File.mkdir_p!(agents_dir)

    # Write per-instance file for each agent entry; collect IDs.
    agent_ids =
      Enum.map(agents, fn agent ->
        instance_id = UUID.uuid4()
        type = Map.get(agent, "type") || ""
        name = Map.get(agent, "name") || ""
        config = Map.get(agent, "config") || %{}

        inst = %Instance{
          id: instance_id,
          session_ids: [sid],
          type: type,
          name: name,
          config: config,
          created_at: doc["created_at"] || DateTime.utc_now() |> DateTime.to_iso8601()
        }

        path = Path.join(agents_dir, instance_id <> ".json")
        :ok = InstanceJson.write(path, inst)
        instance_id
      end)

    # Build the v2 session.json: replace `agents` with `agent_ids`,
    # bump schema_version, drop deprecated v1 keys.
    v2_doc =
      doc
      |> Map.delete("agents")
      |> Map.put("schema_version", 2)
      |> Map.put("agent_ids", agent_ids)
      |> Map.put("primary_agent", primary)

    tmp = session_json_path <> ".tmp"
    File.write!(tmp, Jason.encode!(v2_doc, pretty: true))
    File.rename!(tmp, session_json_path)

    :migrated
  end

  defp do_migrate(_path, _doc), do: {:error, :missing_session_id}

  defp v1_present?(sessions_dir) do
    sessions_dir
    |> File.ls!()
    |> Enum.any?(fn entry ->
      path = Path.join([sessions_dir, entry, "session.json"])

      case File.read(path) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, %{"schema_version" => 1}} -> true
            _ -> false
          end

        _ ->
          false
      end
    end)
  end
end
