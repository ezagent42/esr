defmodule Esr.Admin.Commands.Scope.List do
  @moduledoc """
  `Esr.Admin.Commands.Scope.List` — list live sessions, optionally
  scoped to a workspace via `args.workspace` (PR-21j).

  ## Shapes

  ### PR-21j workspace-scoped (new)

      args: %{"workspace" => "esr-dev", "username" => "linyilun"}
      args.env optional (defaults to $ESR_INSTANCE)

      → {:ok, %{
          "workspace" => "esr-dev",
          "sessions" => [
            %{"name" => "feature-foo", "session_id" => "..."},
            ...
          ]
        }}

  Reads `Esr.SessionRegistry.list_uris/3` — the URI-keyed live-session
  table claimed at /new-session time (PR-21g). Independent of the
  legacy routing.yaml / branches.yaml shape below.

  ### Legacy (pre-PR-21j)

  Reads routing.yaml + branches.yaml and returns a summary map scoped
  to the submitter (spec §6.4 Session.List, plan DI-10 Task 20).

  Kept for backwards compatibility with admin-CLI submits that don't
  carry a workspace arg. Returns:

      %{
        "active"   => active_branch | nil,
        "targets"  => [branch_name, ...],
        "branches" => [branch_name, ...]
      }
  """

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"submitted_by" => submitter, "args" => %{"workspace" => ws} = args})
      when is_binary(submitter) and is_binary(ws) and ws != "" do
    env = args["env"] || Esr.Paths.current_instance()
    username = args["username"] || ""

    if username == "" do
      {:error,
       %{
         "type" => "invalid_args",
         "message" =>
           "session_list with workspace= requires args.username (esr user) too"
       }}
    else
      sessions =
        Esr.SessionRegistry.list_uris(env, username, ws)
        |> Enum.map(fn {name, sid} ->
          %{"name" => name, "session_id" => sid}
        end)

      {:ok,
       %{
         "workspace" => ws,
         "username" => username,
         "env" => env,
         "sessions" => sessions
       }}
    end
  end

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
