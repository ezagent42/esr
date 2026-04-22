defmodule Esr.Admin.Commands.Session.List do
  @moduledoc """
  `Esr.Admin.Commands.Session.List` — reads routing.yaml +
  branches.yaml and returns a summary map scoped to the submitter
  (spec §6.4 Session.List, plan DI-10 Task 20).

  Return shape:

      %{
        "active"   => active_branch | nil,
        "targets"  => [branch_name, ...],  # submitter-scoped
        "branches" => [branch_name, ...]   # global (branches.yaml)
      }

  `targets` lists only the submitter's configured routing targets so
  the Feishu reply doesn't leak other users' sessions. `branches` is
  the global registry from branches.yaml (the router itself is
  principal-scoped — this is informational for operators).
  """

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"submitted_by" => submitter}) when is_binary(submitter) do
    routing = read_yaml(routing_yaml_path())
    branches = read_yaml(branches_yaml_path())

    principal = get_in(routing, ["principals", submitter]) || %{}
    targets = Map.get(principal, "targets") || %{}

    {:ok,
     %{
       "active" => Map.get(principal, "active"),
       "targets" => Map.keys(targets) |> Enum.sort(),
       "branches" => (Map.get(branches, "branches") || %{}) |> Map.keys() |> Enum.sort()
     }}
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "session_list requires submitted_by"
     }}
  end

  # ------------------------------------------------------------------
  # Internals — missing file → empty map (not an error)
  # ------------------------------------------------------------------

  defp read_yaml(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{} = m} -> m
      _ -> %{}
    end
  end

  defp routing_yaml_path, do: Path.join(Esr.Paths.runtime_home(), "routing.yaml")
  defp branches_yaml_path, do: Path.join(Esr.Paths.runtime_home(), "branches.yaml")
end
