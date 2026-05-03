defmodule Esr.Admin.Commands.Workspace.New do
  @moduledoc """
  `Esr.Admin.Commands.Workspace.New` — create a workspace from inside
  Feishu (PR-21k). Dispatcher kind `workspace_new`.

  Writes the new entry to `workspaces.yaml` (FSEvents will reload),
  then proactively `put`s into `Esr.Resource.Workspace.Registry` so the
  current chat doesn't have to wait for the watcher tick.

  ## Args (PR-22: `root` removed)

      args: %{
        "name" => "esr-dev",                  # required
        # optional — defaults below
        "owner" => "linyilun",                # default: args.username (slash threading)
        "role" => "dev",                      # default
        "start_cmd" => "scripts/esr-cc.sh",   # default
        "chat_id" => "oc_xxx",                # auto-bind this chat to the new workspace
        "app_id"  => "cli_xxx",
        "username" => "linyilun"              # SlashHandler-resolved esr user
      }

  ## Validation

  - `name` must match ASCII `[A-Za-z0-9][A-Za-z0-9_-]*` (PR-M / D13)
  - `owner` must be a registered esr user (in `users.yaml`)
  - workspace name must NOT already exist

  ## Result

      {:ok, %{"name" => name, "owner" => owner, "chats" => […]}}
      {:error, %{"type" => "name_exists" | "invalid_name" | "unknown_owner" | "invalid_args", ...}}
  """

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()} | {:error, map()}

  @name_re ~r/^[A-Za-z0-9][A-Za-z0-9_\-]*$/

  @spec execute(map()) :: result()
  def execute(cmd)

  def execute(%{"args" => %{"name" => name} = args})
      when is_binary(name) and name != "" do
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
        new_chat = build_chat(chat_id, app_id)

        path = Esr.Paths.workspaces_yaml()
        {:ok, doc} = read_or_empty(path)
        ws_map = doc["workspaces"] || %{}

        case Map.fetch(ws_map, name) do
          {:ok, existing} ->
            # PR-21η 2026-04-30: idempotent path. Pre-PR-21η this was a
            # `name_exists` error, which made sense before slash auto-
            # binding existed. Now that `/new-workspace <existing>` from
            # an unbound chat is a legitimate "please add my chat to
            # this workspace" gesture (the alternative is asking
            # operators to hand-edit workspaces.yaml), we treat it as
            # add-chat-if-missing and return :ok with `action: "added_chat"`.
            handle_existing_workspace(name, existing, new_chat, ws_map, doc, path)

          :error ->
            new_entry = %{
              "owner" => owner,
              "role" => role,
              "start_cmd" => start_cmd,
              "chats" => new_chat |> List.wrap(),
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
                  Esr.Resource.Workspace.Registry.put(%Esr.Resource.Workspace.Registry.Workspace{
                    name: name,
                    owner: owner,
                    role: role,
                    start_cmd: start_cmd,
                    chats: List.wrap(new_chat),
                    env: %{}
                  })

                {:ok,
                 %{
                   "name" => name,
                   "owner" => owner,
                   "role" => role,
                   "chats" => List.wrap(new_chat),
                   "action" => "created"
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
       "message" => "workspace_new requires args.name (non-empty string)"
     }}
  end

  # PR-21η: when /new-workspace targets an existing workspace, decide
  # what to do based on whether the current chat is already in chats:
  #
  #   - chat already bound → :ok, action="already_bound" (no write)
  #   - chat not yet bound + we know the chat → append to chats: + write
  #   - no chat known (CLI invocation, no slash context) → :error
  #     (preserves the pre-PR-21η name_exists behavior for that path)
  defp handle_existing_workspace(name, existing, new_chat, ws_map, doc, path) do
    existing_chats = existing["chats"] || []

    cond do
      new_chat == nil ->
        {:error,
         %{
           "type" => "name_exists",
           "name" => name,
           "message" =>
             "workspace #{inspect(name)} already exists; pick another name or delete the old one (`esr workspace remove #{name}`)"
         }}

      chat_already_bound?(existing_chats, new_chat) ->
        {:ok,
         %{
           "name" => name,
           "owner" => existing["owner"],
           "role" => existing["role"],
           "chats" => existing_chats,
           "action" => "already_bound"
         }}

      true ->
        updated_chats = existing_chats ++ [new_chat]
        updated_entry = Map.put(existing, "chats", updated_chats)

        updated_doc =
          doc
          |> Map.put("schema_version", doc["schema_version"] || 1)
          |> Map.put("workspaces", Map.put(ws_map, name, updated_entry))

        case Esr.Yaml.Writer.write(path, updated_doc) do
          :ok ->
            :ok =
              Esr.Resource.Workspace.Registry.put(%Esr.Resource.Workspace.Registry.Workspace{
                name: name,
                owner: existing["owner"],
                role: existing["role"],
                start_cmd: existing["start_cmd"],
                chats: updated_chats,
                env: existing["env"] || %{}
              })

            {:ok,
             %{
               "name" => name,
               "owner" => existing["owner"],
               "role" => existing["role"],
               "chats" => updated_chats,
               "action" => "added_chat"
             }}

          {:error, reason} ->
            {:error, %{"type" => "write_failed", "details" => inspect(reason)}}
        end
    end
  end

  defp chat_already_bound?(chats, %{"chat_id" => cid, "app_id" => aid}) do
    Enum.any?(chats, fn c ->
      is_map(c) and c["chat_id"] == cid and c["app_id"] == aid
    end)
  end

  defp chat_already_bound?(_chats, _new_chat), do: false

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

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

  # PR-21η: returns a single chat map or nil (instead of a list). nil
  # signals "no slash context" — used by handle_existing_workspace/6 to
  # distinguish CLI invocations from slash invocations.
  defp build_chat(chat_id, app_id)
       when is_binary(chat_id) and chat_id != "" and is_binary(app_id) and app_id != "" do
    %{"chat_id" => chat_id, "app_id" => app_id, "kind" => "dm"}
  end

  defp build_chat(_chat_id, _app_id), do: nil

  defp read_or_empty(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{} = m} -> {:ok, m}
      _ -> {:ok, %{"schema_version" => 1, "workspaces" => %{}}}
    end
  end
end
