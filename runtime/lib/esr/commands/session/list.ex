defmodule Esr.Commands.Session.List do
  @moduledoc """
  `Esr.Commands.Session.List` — list live sessions, optionally
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

  Reads `Esr.Session.NameIndex.Registry.list_uris/3` — the URI-keyed live-session
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

  use Esr.Commands.Meta

  command :session_list do
    slash         "/session:list"
    category      "Sessions"
    description   "列当前 chat 绑定的 session(无 workspace=);带 workspace= 时按 workspace 列"
    permission    "session:default/read"
    requires_user_binding      true
    requires_workspace_binding false

    arg :workspace, required: false, doc: "scope by workspace name"

    error :invalid_args,       "session_list %{detail}"
    error :unknown_workspace,  "workspace %{workspace} not found"
  end

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()} | {:error, map()}

  alias Esr.Commands.Render

  @spec execute(map()) :: result()
  def execute(%{"submitted_by" => submitter, "args" => %{"workspace" => ws} = args})
      when is_binary(submitter) and is_binary(ws) and ws != "" do
    env = args["env"] || Esr.Paths.current_instance()
    username = args["username"] || ""

    cond do
      username == "" ->
        Render.error(__MODULE__.command_meta(), :invalid_args, %{
          detail: "with workspace= requires args.username (esr user) too"
        })

      not workspace_exists?(ws) ->
        Render.error(__MODULE__.command_meta(), :unknown_workspace, %{workspace: ws})

      true ->
        sessions =
          Esr.Session.NameIndex.Registry.list_uris(env, username, ws)
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

  def execute(%{
        "submitted_by" => submitter,
        "args" => %{"chat_id" => chat_id, "app_id" => app_id}
      })
      when is_binary(submitter) and is_binary(chat_id) and chat_id != "" and
             is_binary(app_id) and app_id != "" do
    sessions =
      case Esr.Session.ChatRouting.Registry.list_sessions(chat_id, app_id) do
        sids when is_list(sids) ->
          Enum.map(sids, fn sid -> %{"session_id" => sid} end)

        _ ->
          []
      end

    {:ok,
     %{
       "chat_id" => chat_id,
       "app_id" => app_id,
       "sessions" => sessions
     }}
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
    Render.error(__MODULE__.command_meta(), :invalid_args, %{
      detail: "requires submitted_by"
    })
  end

  # ------------------------------------------------------------------
  # Internals — missing file → empty map (not an error)
  # ------------------------------------------------------------------

  defp workspace_exists?(ws_name) do
    case Esr.Uri.Compat.uuid_for_workspace_name(ws_name) do
      {:ok, _} -> true
      :not_found -> false
    end
  rescue
    # URI store ETS table not created (admin-CLI use without full app boot)
    ArgumentError -> true
  end

  defp read_yaml(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{} = m} -> m
      _ -> %{}
    end
  end

  defp routing_yaml_path, do: Path.join(Esr.Paths.runtime_home(), "routing.yaml")
  defp branches_yaml_path, do: Path.join(Esr.Paths.runtime_home(), "branches.yaml")
end
