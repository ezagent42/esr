defmodule Esr.Commands.Workspace.Resolve do
  @moduledoc """
  Single workspace-resolution chain shared by `/session:new` and
  `/workspace:add-folder` (M-5).

  Specificity ladder:

      1. explicit args["workspace"]                  ← {:explicit, name}
      2. chat-default via ChatScope.Registry         ← {:chat_default, name}
      3. user-default via User.Registry              ← {:user_default, name}
      4. :no_match                                   ← caller maps to error

  The resolver only returns workspace **names** (not UUIDs); callers
  re-resolve via `Esr.Uri.Compat.uuid_for_workspace_name/1` if they
  need the UUID — keeps the chain pure and testable without a UUID
  mocking layer.

  Submitter is sourced from `args["submitter_username"]` when present,
  otherwise resolved from `args["submitted_by"]` which can carry any
  of the three principal forms:

    * Feishu `ou_*` open_id   → `username_for_feishu_id/1`
    * UUID                    → `name_for_user_uuid/1`
    * username (CLI shorthand) → trusted as-is

  The UUID branch is what makes CLI submits work: `operator.json`
  writes `caller_principal_id` as the user's UUID (`b31e9dcc-...`)
  after `user_add`, so every subsequent `esr exec <slash>` invocation
  threads UUID into `submitted_by`. Pre-fix the resolver only knew
  `ou_*` form, so `submitted_by=<uuid>` quietly returned `:not_found`
  and the user-default workspace fallback never fired — operators
  saw `no_workspace_target` on bare `/session:new name=test-cc`
  (team todo `resolve-submitter-format-agnostic`, walkthrough-4 #349).
  """

  alias Esr.Session.ChatRouting.Registry, as: ChatScope

  @type tag ::
          {:explicit, String.t()}
          | {:chat_default, String.t()}
          | {:user_default, String.t()}
          | :no_match

  @spec resolve_workspace_for_args(map()) :: tag()
  def resolve_workspace_for_args(args) when is_map(args) do
    cond do
      is_binary(args["workspace"]) and args["workspace"] != "" ->
        {:explicit, args["workspace"]}

      (chat_default_name = lookup_chat_default(args)) != nil ->
        {:chat_default, chat_default_name}

      (user_default_name = lookup_user_default(args)) != nil ->
        {:user_default, user_default_name}

      true ->
        :no_match
    end
  end

  defp lookup_chat_default(args) do
    with chat_id when is_binary(chat_id) and chat_id != "" <- args["chat_id"],
         app_id when is_binary(app_id) and app_id != "" <- args["app_id"],
         {:ok, ws_uuid} <- ChatScope.get_default_workspace(chat_id, app_id),
         {:ok, ws} <- Esr.Uri.Compat.workspace_by_uuid(ws_uuid) do
      ws.name
    else
      _ -> nil
    end
  end

  defp lookup_user_default(args) do
    with {:ok, username} <- resolve_submitter(args),
         {:ok, ws_uuid} <- Esr.Uri.Compat.default_workspace_for_user_name(username),
         {:ok, ws} <- Esr.Uri.Compat.workspace_by_uuid(ws_uuid) do
      ws.name
    else
      _ -> nil
    end
  end

  defp resolve_submitter(%{"submitter_username" => username})
       when is_binary(username) and username != "",
       do: {:ok, username}

  defp resolve_submitter(%{"submitted_by" => id}) when is_binary(id) and id != "" do
    resolve_principal_to_username(id)
  end

  defp resolve_submitter(_), do: :not_found

  # Walkthrough-4 #349. Detect the form of an inbound principal id
  # string and resolve it to the canonical esr username.
  #
  # Order of detection matters only for ambiguous inputs; in practice
  # `ou_*` and UUID shapes are disjoint and a bare username never
  # starts with `ou_` nor matches the UUID regex. So `cond do` falls
  # through to the username branch for anything that doesn't match
  # the structured forms — treating it as a username is the right
  # default for admin-queue submits that already carry the canonical
  # handle.
  defp resolve_principal_to_username(id) do
    cond do
      String.starts_with?(id, "ou_") ->
        Esr.Uri.Compat.username_for_feishu_id(id)

      looks_like_uuid?(id) ->
        Esr.Uri.Compat.name_for_user_uuid(id)

      true ->
        {:ok, id}
    end
  end

  @uuid_re ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
  defp looks_like_uuid?(s) when is_binary(s), do: Regex.match?(@uuid_re, s)

  # Convenience for callers that only need a name and don't care which
  # layer hit — used by /workspace:add-folder.
  @spec workspace_name_for_args(map()) :: {:ok, String.t()} | :no_match
  def workspace_name_for_args(args) do
    case resolve_workspace_for_args(args) do
      {_tag, name} -> {:ok, name}
      :no_match -> :no_match
    end
  end

  # Convenience for callers that need the UUID directly.
  @spec workspace_id_for_args(map()) :: {:ok, String.t()} | :no_match | :workspace_gone
  def workspace_id_for_args(args) do
    with {:ok, name} <- workspace_name_for_args(args),
         {:ok, id} <- Esr.Uri.Compat.uuid_for_workspace_name(name) do
      {:ok, id}
    else
      :no_match -> :no_match
      :not_found -> :workspace_gone
    end
  rescue
    ArgumentError -> :no_match
  end
end
