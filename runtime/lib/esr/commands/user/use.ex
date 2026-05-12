defmodule Esr.Commands.User.Use do
  @moduledoc """
  `/user:use workspace=<name>` — set the submitting user's default
  workspace.

  Symmetric to `/workspace:use` (which sets the chat-default). The
  user-default is the third layer of the `/session:new` workspace
  fallback chain (see `Esr.Commands.Workspace.Resolve`).

  ## Args
      args: %{"workspace" => "esr-dev"}

  ## Result shape
      {:ok,  %{"action" => "user_default_set",
               "username" => "alice", "workspace" => "esr-dev",
               "workspace_id" => "<uuid>"}}
      {:error, %{"type" => "invalid_args" | "unknown_workspace" |
                              "unknown_user", ...}}
  """

  use Esr.Commands.Meta

  command :user_use do
    slash         "/user:use"
    category      "Users"
    description   "设当前 user 的 default workspace（per-user 偏好；/session:new fallback 链中 user-default 这一层）"
    permission    "workspace.create"
    requires_user_binding      true
    requires_workspace_binding false

    arg :workspace, required: true, doc: "目标 workspace 名"

    error :invalid_args,        "/user:use requires args.workspace (non-empty string)"
    error :unknown_workspace,   "workspace '%{workspace}' not found"
    error :unknown_user,        "%{detail}"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render
  alias Esr.Resource.Workspace.NameIndex, as: WsNameIndex
  alias Esr.Resource.Workspace.Registry, as: WsRegistry

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"workspace" => ws_name}} = cmd)
      when is_binary(ws_name) and ws_name != "" do
    with {:ok, username} <- resolve_submitter(cmd),
         {:ok, ws_id} <- resolve_workspace_id(ws_name),
         :ok <- Esr.Uri.Compat.set_default_workspace_for_user_name(username, ws_id),
         :ok <- persist_default_to_user_json(username, ws_id) do
      {:ok,
       %{
         "action" => "user_default_set",
         "username" => username,
         "workspace" => ws_name,
         "workspace_id" => ws_id
       }}
    end
  end

  def execute(_cmd) do
    Render.error(__MODULE__.command_meta(), :invalid_args)
  end

  # Submitter is sourced from either the cmd top-level (slash plumbing
  # populates `submitted_by` + sometimes `submitter_username`) or from
  # `args["submitter_username"]` (admin-submit / e2e harness path that
  # only nests args). Try both layers; prefer the explicit-username
  # form over the ou_id lookup.
  defp resolve_submitter(cmd) do
    args = Map.get(cmd, "args") || %{}

    cond do
      is_binary(cmd["submitter_username"]) and cmd["submitter_username"] != "" ->
        {:ok, cmd["submitter_username"]}

      is_binary(args["submitter_username"]) and args["submitter_username"] != "" ->
        {:ok, args["submitter_username"]}

      is_binary(cmd["submitted_by"]) and cmd["submitted_by"] != "" ->
        case Esr.Uri.Compat.username_for_feishu_id(cmd["submitted_by"]) do
          {:ok, username} ->
            {:ok, username}

          :not_found ->
            Render.error(__MODULE__.command_meta(), :unknown_user, %{
              detail: "submitter #{cmd["submitted_by"]} has no esr-user binding"
            })
        end

      true ->
        Render.error(__MODULE__.command_meta(), :unknown_user, %{
          detail: "no submitter context"
        })
    end
  end

  # Spec §4.3 invariant: the user-default binding must survive an esrd
  # restart. ETS-only set_default_workspace is rebuilt on boot from
  # user.json by FileLoader, so the canonical write goes here.
  # Single-field update on the existing user.json (keep schema_version,
  # id, username, feishu_ids, display_name, created_at intact) — atomic
  # via tmp+rename. Missing-uuid in NameIndex is silently skipped: the
  # ETS write already succeeded, so the in-memory state is correct
  # within this boot; the disk-write is a best-effort durability layer.
  defp persist_default_to_user_json(username, ws_id) do
    case Esr.Uri.Compat.uuid_for_user_name(:esr_user_name_index, username) do
      {:ok, uuid} -> rewrite_user_json_default(uuid, ws_id)
      :not_found -> :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp rewrite_user_json_default(uuid, ws_id) do
    path = Path.join([Esr.Paths.users_dir(), uuid, "user.json"])

    with {:ok, raw} <- File.read(path),
         {:ok, doc} <- Jason.decode(raw) do
      tmp = path <> ".tmp"
      updated = Map.put(doc, "default_workspace_id", ws_id)

      with :ok <- File.write(tmp, Jason.encode!(updated, pretty: true)),
           :ok <- File.rename(tmp, path) do
        :ok
      end
    else
      {:error, :enoent} -> :ok
      {:error, _} = err -> err
    end
  rescue
    e -> {:error, e}
  end

  defp resolve_workspace_id(ws_name) do
    case WsNameIndex.id_for_name(:esr_workspace_name_index, ws_name) do
      {:ok, ws_id} ->
        case WsRegistry.get_by_id(ws_id) do
          {:ok, _} -> {:ok, ws_id}
          :not_found -> workspace_not_found(ws_name)
        end

      :not_found ->
        workspace_not_found(ws_name)
    end
  rescue
    ArgumentError -> workspace_not_found(ws_name)
  end

  defp workspace_not_found(ws_name) do
    Render.error(__MODULE__.command_meta(), :unknown_workspace, %{workspace: ws_name})
  end
end
