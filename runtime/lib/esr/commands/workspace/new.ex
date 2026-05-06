defmodule Esr.Commands.Workspace.New do
  @moduledoc """
  `/new-workspace` slash — creates a workspace with hybrid storage:

    * `folder=<path>` → repo-bound (`<path>/.esr/workspace.json`)
    * no `folder=` → ESR-bound (`$ESRD_HOME/<inst>/workspaces/<name>/workspace.json`)

  Generates a fresh UUID v4 for the workspace's identity. Auto-binds the
  current chat to chats[] when `chat_id` + `app_id` are present.

  ## Args

      args: %{
        "name"      => "esr-dev",         # required
        "folder"    => "/abs/path/repo",  # optional; must be a git repo if given
        "owner"     => "linyilun",        # default: args.username (slash threading)
        "transient" => false,             # optional; only valid for ESR-bound
        "chat_id"   => "oc_xxx",          # auto-injected from envelope
        "app_id"    => "cli_xxx",
        "username"  => "linyilun"         # SlashHandler-resolved esr user
      }

  ## Result

      {:ok,  %{"name" => name, "id" => uuid, "owner" => owner, "folders" => [...],
               "chats" => [...], "location" => "esr:<dir>"|"repo:<path>",
               "action" => "created" | "already_bound" | "added_chat"}}
      {:error, %{"type" => "invalid_name" | "unknown_owner" | "invalid_args" |
                            "folder_not_dir" | "folder_not_git_repo" |
                            "transient_repo_bound_forbidden" | "name_exists" |
                            "registry_put_failed", ...}}
  """

  @behaviour Esr.Role.Control

  @name_re ~r/^[A-Za-z0-9][A-Za-z0-9_\-]*$/

  alias Esr.Resource.Workspace.{Struct, Registry, NameIndex, RepoRegistry}

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(cmd)

  def execute(%{"args" => %{"name" => name} = args})
      when is_binary(name) and name != "" do
    owner = args["owner"] || args["username"] || ""
    folder = args["folder"]
    transient = parse_bool(args["transient"])
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

      folder != nil and not File.dir?(folder) ->
        {:error, %{"type" => "folder_not_dir", "folder" => folder}}

      folder != nil and not File.exists?(Path.join(folder, ".git")) ->
        {:error, %{"type" => "folder_not_git_repo", "folder" => folder}}

      folder != nil and transient ->
        {:error,
         %{
           "type" => "transient_repo_bound_forbidden",
           "message" => "transient: true is not valid for repo-bound workspaces"
         }}

      true ->
        do_create_or_bind(name, owner, folder, transient, chat_id, app_id)
    end
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "workspace_new requires args.name (non-empty string)"
     }}
  end

  ## Internals ---------------------------------------------------------------

  defp do_create_or_bind(name, owner, folder, transient, chat_id, app_id) do
    case lookup_struct_by_name(name) do
      {:ok, existing} -> handle_existing(name, existing, chat_id, app_id)
      :not_found -> create_new(name, owner, folder, transient, chat_id, app_id)
    end
  end

  defp create_new(name, owner, folder, transient, chat_id, app_id) do
    chats = build_chats(chat_id, app_id)

    location =
      case folder do
        nil -> {:esr_bound, Esr.Paths.workspace_dir(name)}
        path -> {:repo_bound, path}
      end

    folders =
      case folder do
        nil -> []
        path -> [%{path: path, name: Path.basename(path)}]
      end

    ws = %Struct{
      id: UUID.uuid4(),
      name: name,
      owner: owner,
      folders: folders,
      agent: "cc",
      settings: %{},
      env: %{},
      chats: chats,
      transient: transient && folder == nil,
      location: location
    }

    case Registry.put(ws) do
      :ok ->
        # Repo-bound: also register the path in registered_repos.yaml
        if folder do
          RepoRegistry.register(Esr.Paths.registered_repos_yaml(), folder)
        end

        {:ok,
         %{
           "name" => name,
           "id" => ws.id,
           "owner" => owner,
           "folders" => serialise_folders(folders),
           "chats" => serialise_chats(chats),
           "location" => format_location(ws.location),
           "action" => "created"
         }}

      {:error, reason} ->
        {:error, %{"type" => "registry_put_failed", "detail" => inspect(reason)}}
    end
  end

  # Idempotent path (PR-21η behaviour preserved):
  #   - no chat context (CLI invocation) → name_exists error
  #   - chat already bound → :ok, action="already_bound" (no write)
  #   - chat not yet bound → append chat and write
  defp handle_existing(name, %Struct{} = existing, chat_id, app_id) do
    new_chat = build_single_chat(chat_id, app_id)

    cond do
      new_chat == nil ->
        {:error,
         %{
           "type" => "name_exists",
           "name" => name,
           "message" =>
             "workspace #{inspect(name)} already exists; pick another name or delete the old one (`esr workspace remove #{name}`)"
         }}

      Enum.any?(existing.chats, fn c ->
        c.chat_id == new_chat.chat_id and c.app_id == new_chat.app_id
      end) ->
        {:ok,
         %{
           "name" => name,
           "id" => existing.id,
           "chats" => serialise_chats(existing.chats),
           "action" => "already_bound"
         }}

      true ->
        updated_chats = existing.chats ++ [new_chat]
        updated = %{existing | chats: updated_chats}

        case Registry.put(updated) do
          :ok ->
            {:ok,
             %{
               "name" => name,
               "id" => existing.id,
               "chats" => serialise_chats(updated_chats),
               "action" => "added_chat"
             }}

          {:error, reason} ->
            {:error, %{"type" => "registry_put_failed", "detail" => inspect(reason)}}
        end
    end
  end

  defp lookup_struct_by_name(name) do
    case NameIndex.id_for_name(:esr_workspace_name_index, name) do
      {:ok, id} -> Registry.get_by_id(id)
      :not_found -> :not_found
    end
  end

  defp build_chats(chat_id, app_id) do
    case build_single_chat(chat_id, app_id) do
      nil -> []
      chat -> [chat]
    end
  end

  defp build_single_chat(chat_id, app_id)
       when is_binary(chat_id) and chat_id != "" and is_binary(app_id) and app_id != "",
       do: %{chat_id: chat_id, app_id: app_id, kind: "dm"}

  defp build_single_chat(_, _), do: nil

  defp format_location({:esr_bound, dir}), do: "esr:#{dir}"
  defp format_location({:repo_bound, repo}), do: "repo:#{repo}"

  # Serialise atom-keyed chat structs to string-keyed maps for the result.
  defp serialise_chats(chats),
    do: Enum.map(chats, fn c -> %{"chat_id" => c.chat_id, "app_id" => c.app_id, "kind" => Map.get(c, :kind, "dm")} end)

  defp serialise_folders(folders),
    do: Enum.map(folders, fn f -> %{"path" => f.path, "name" => Map.get(f, :name)} end)

  defp parse_bool("true"), do: true
  defp parse_bool(true), do: true
  defp parse_bool(_), do: false

  defp owner_exists?(username) do
    if Process.whereis(Esr.Entity.User.Registry) do
      case Esr.Entity.User.Registry.get(username) do
        {:ok, _} -> true
        :not_found -> false
      end
    else
      # Tests that don't bring up Users.Registry shouldn't crash here.
      true
    end
  end
end
