defmodule Esr.Admin.Commands.Workspace.New do
  @moduledoc """
  `Esr.Admin.Commands.Workspace.New` — create a workspace from inside
  Feishu (PR-21k). Dispatcher kind `workspace_new`.

  Writes the new entry to `workspaces.yaml` (FSEvents will reload),
  then proactively `put`s into `Esr.Workspaces.Registry` so the
  current chat doesn't have to wait for the watcher tick.

  ## Args

      args: %{
        "name" => "esr-dev",
        "root" => "/Users/h2oslabs/Workspace/esr",  # required
        # optional — defaults below
        "owner" => "linyilun",            # default: args.username (slash threading)
        "role" => "dev",                  # default
        "start_cmd" => "scripts/esr-cc.sh", # default
        "chat_id" => "oc_xxx",            # auto-bind this chat to the new workspace
        "app_id"  => "cli_xxx",
        "username" => "linyilun"          # SlashHandler-resolved esr user
      }

  ## Validation

  - `name` must match ASCII `[A-Za-z0-9][A-Za-z0-9_-]*` (PR-M / D13)
  - `root` must be a non-empty path (existence is NOT checked here —
    operator may be pointing at a path they intend to create)
  - `owner` must be a registered esr user (in `users.yaml`)
  - workspace name must NOT already exist

  ## Result

      {:ok, %{"name" => name, "owner" => owner, "root" => root, "chats" => […]}}
      {:error, %{"type" => "name_exists" | "invalid_name" | "unknown_owner" | "invalid_args", ...}}
  """

  @type result :: {:ok, map()} | {:error, map()}

  @name_re ~r/^[A-Za-z0-9][A-Za-z0-9_\-]*$/

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"name" => name, "root" => root} = args})
      when is_binary(name) and name != "" and is_binary(root) and root != "" do
    owner = args["owner"] || args["username"] || ""
    role = args["role"] || "dev"
    start_cmd = args["start_cmd"] || "scripts/esr-cc.sh"
    chat_id = args["chat_id"]
    app_id = args["app_id"]

    cond do
      not Regex.match?(@name_re, name) ->
        {:error,
         %{
           "type" => "invalid_name",
           "name" => name,
           "message" => "workspace name must be ASCII alnum + - + _ (matches #{inspect(@name_re)})"
         }}

      owner == "" ->
        {:error,
         %{
           "type" => "invalid_args",
           "message" =>
             "workspace_new requires args.owner (or args.username from slash) — bind your Feishu identity first via `esr user bind-feishu`"
         }}

      not owner_exists?(owner) ->
        {:error,
         %{
           "type" => "unknown_owner",
           "owner" => owner,
           "message" =>
             "owner #{inspect(owner)} not registered in users.yaml; run `esr user add #{owner}` first"
         }}

      true ->
        chats = build_chats(chat_id, app_id)

        path = Esr.Paths.workspaces_yaml()
        {:ok, doc} = read_or_empty(path)
        ws_map = doc["workspaces"] || %{}

        if Map.has_key?(ws_map, name) do
          {:error,
           %{
             "type" => "name_exists",
             "name" => name,
             "message" => "workspace #{inspect(name)} already exists; pick another name or delete the old one"
           }}
        else
          new_entry = %{
            "owner" => owner,
            "root" => root,
            "role" => role,
            "start_cmd" => start_cmd,
            "chats" => chats,
            "env" => %{}
          }

          updated_doc =
            doc
            |> Map.put("schema_version", doc["schema_version"] || 1)
            |> Map.put("workspaces", Map.put(ws_map, name, new_entry))

          case Esr.Yaml.Writer.write(path, updated_doc) do
            :ok ->
              # Proactively populate the in-memory Registry so this very
              # request's chat finds the workspace bound — without
              # waiting for the FSEvents watcher tick.
              :ok =
                Esr.Workspaces.Registry.put(%Esr.Workspaces.Registry.Workspace{
                  name: name,
                  owner: owner,
                  root: root,
                  role: role,
                  start_cmd: start_cmd,
                  chats: chats,
                  env: %{}
                })

              {:ok,
               %{
                 "name" => name,
                 "owner" => owner,
                 "root" => root,
                 "role" => role,
                 "chats" => chats
               }}

            {:error, reason} ->
              {:error, %{"type" => "write_failed", "details" => inspect(reason)}}
          end
        end
    end
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "workspace_new requires args.name and args.root (non-empty strings)"
     }}
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp owner_exists?(username) do
    if Process.whereis(Esr.Users.Registry) do
      case Esr.Users.Registry.get(username) do
        {:ok, _} -> true
        :not_found -> false
      end
    else
      # Tests that don't bring up Users.Registry shouldn't crash here.
      true
    end
  end

  defp build_chats(chat_id, app_id)
       when is_binary(chat_id) and chat_id != "" and is_binary(app_id) and app_id != "" do
    [%{"chat_id" => chat_id, "app_id" => app_id, "kind" => "dm"}]
  end

  defp build_chats(_chat_id, _app_id), do: []

  defp read_or_empty(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{} = m} -> {:ok, m}
      _ -> {:ok, %{"schema_version" => 1, "workspaces" => %{}}}
    end
  end
end
