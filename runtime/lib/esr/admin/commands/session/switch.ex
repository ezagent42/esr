defmodule Esr.Admin.Commands.Session.Switch do
  @moduledoc """
  `Esr.Admin.Commands.Session.Switch` — flips the submitter's active
  routing target to the requested branch (spec §6.4 Session.Switch,
  plan DI-10 Task 20).

  Pure `routing.yaml` read-modify-write. The SlashHandler observes the
  change via its fs_watch and refreshes its in-memory routing map (no
  need to notify anything explicitly).

  ## Result

    * `{:ok, %{"active_branch" => branch}}` on success.
    * `{:error, %{"type" => "invalid_args"}}` — missing `args.branch` /
      `submitted_by`.
    * `{:error, %{"type" => "no_such_target"}}` — submitter has no
      entry in `routing.yaml`, or the branch isn't one of their
      `targets`. Session.New is the way to create a target; Switch
      refuses to materialize one out of thin air.
  """

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"submitted_by" => submitter, "args" => %{"branch" => branch}})
      when is_binary(submitter) and is_binary(branch) and branch != "" do
    path = routing_yaml_path()

    case read_routing(path) do
      {:ok, current} ->
        principals = Map.get(current, "principals") || %{}
        principal = Map.get(principals, submitter)
        targets = (principal && Map.get(principal, "targets")) || %{}

        cond do
          is_nil(principal) -> {:error, %{"type" => "no_such_target"}}
          not Map.has_key?(targets, branch) -> {:error, %{"type" => "no_such_target"}}
          true -> write_active(path, current, principals, principal, submitter, branch)
        end

      {:error, :missing} ->
        {:error, %{"type" => "no_such_target"}}
    end
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "session_switch requires submitted_by and args.branch (non-empty string)"
     }}
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp read_routing(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{} = m} -> {:ok, m}
      _ -> {:error, :missing}
    end
  end

  defp write_active(path, current, principals, principal, submitter, branch) do
    updated_principal = Map.put(principal, "active", branch)

    updated =
      Map.put(current, "principals", Map.put(principals, submitter, updated_principal))

    case Esr.Yaml.Writer.write(path, updated) do
      :ok -> {:ok, %{"active_branch" => branch}}
      {:error, reason} -> {:error, %{"type" => "write_failed", "detail" => inspect(reason)}}
    end
  end

  defp routing_yaml_path, do: Path.join(Esr.Paths.runtime_home(), "routing.yaml")
end
