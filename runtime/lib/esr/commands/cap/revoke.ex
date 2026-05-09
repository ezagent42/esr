defmodule Esr.Commands.Cap.Revoke do
  @moduledoc """
  `Esr.Commands.Cap.Revoke` — removes a permission from a
  principal's capability list in `capabilities.yaml` (dev-prod-
  isolation spec §6.4 Cap.Revoke bullet, plan DI-10 Task 23).

  Called by `Esr.Admin.Dispatcher` inside a `Task.start` when a
  `revoke`-kind command reaches the front of the queue. Pure function
  module (no GenServer).

  ## Flow

    1. Read `capabilities.yaml` via `YamlElixir`.
    2. Missing file → `{:error, %{"type" => "no_matching_capability"}}`
       (nothing to revoke from an absent file).
    3. Locate the principal by `id`. Missing → same error.
    4. Remove the permission from the principal's `capabilities` list.
       Not held → same error.
    5. Write back via `Esr.Yaml.Writer`. The file-level
       `Esr.Resource.Capability.Watcher` reloads ETS automatically.

  ## Result

    * `{:ok, %{"principal_id" => id, "permission" => perm, "action" => "revoked"}}`
    * `{:error, %{"type" => "no_matching_capability"}}` — file missing,
      principal missing, or permission not held. One stable shape so
      the CLI surface can map it to a single "nothing to revoke"
      message regardless of the concrete cause.
    * `{:error, %{"type" => "invalid_args", ...}}` — malformed command.
  """

  use Esr.Commands.Meta

  command :cap_revoke do
    slash         "/cap:revoke"
    category      "Capabilities"
    description   "撤销用户的 cap；session cap 仅接受 UUID 形式"
    permission    "cap.manage"
    requires_user_binding      false
    requires_workspace_binding false

    arg :cap,  required: true, doc: "permission 字符串（session cap 必须是 UUID 形式）"
    arg :user, required: true, doc: "principal id"

    error :session_cap_requires_uuid, "%{detail}"
    error :unknown_workspace,         "no workspace found in capability scope: %{permission}"
    error :no_matching_capability,    "no matching capability to revoke"
    error :invalid_args,              "revoke requires args.principal_id and args.permission (non-empty strings)"
    error :write_failed,              "%{detail}"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"principal_id" => pid, "permission" => perm}})
      when is_binary(pid) and pid != "" and is_binary(perm) and perm != "" do
    with :ok <- validate_session_cap(perm),
         {:ok, translated_perm} <- Esr.Resource.Capability.UuidTranslator.name_to_uuid(perm) do
      do_revoke(pid, translated_perm)
    else
      {:error, {:session_name_in_cap, msg}} ->
        Render.error(__MODULE__.command_meta(), :session_cap_requires_uuid, %{detail: msg})

      {:error, :unknown_workspace} ->
        Render.error(__MODULE__.command_meta(), :unknown_workspace, %{permission: perm})
    end
  end

  def execute(_cmd) do
    Render.error(__MODULE__.command_meta(), :invalid_args)
  end

  defp validate_session_cap(perm) do
    Esr.Resource.Capability.UuidTranslator.validate_session_cap_input(perm)
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp do_revoke(pid, perm) do
    path = Esr.Paths.capabilities_yaml()

    with {:ok, %{} = doc} <- read_yaml(path),
         principals when is_list(principals) <- Map.get(doc, "principals"),
         {:ok, updated_principals} <- remove_grant(principals, pid, perm) do
      updated_doc = Map.put(doc, "principals", updated_principals)

      case Esr.Yaml.Writer.write(path, updated_doc) do
        :ok ->
          {:ok,
           %{
             "principal_id" => pid,
             "permission" => perm,
             "action" => "revoked"
           }}

        {:error, reason} ->
          Render.error(__MODULE__.command_meta(), :write_failed, %{detail: inspect(reason)})
      end
    else
      :no_match ->
        Render.error(__MODULE__.command_meta(), :no_matching_capability)

      _ ->
        Render.error(__MODULE__.command_meta(), :no_matching_capability)
    end
  end

  # Missing / unreadable file → treat as "no matching cap" so the
  # operator sees one error type regardless of how the mismatch arose.
  defp read_yaml(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{} = m} -> {:ok, m}
      _ -> :no_match
    end
  end

  # Locate the principal by id, drop the permission from its
  # capabilities list. Returns :no_match if principal is missing or
  # the permission isn't held.
  defp remove_grant(principals, pid, perm) do
    case Enum.find(principals, fn p -> is_map(p) and p["id"] == pid end) do
      nil ->
        :no_match

      existing ->
        caps = Map.get(existing, "capabilities") || []

        if perm in caps do
          updated = Map.put(existing, "capabilities", List.delete(caps, perm))

          new_principals =
            Enum.map(principals, fn
              p when is_map(p) ->
                if p["id"] == pid, do: updated, else: p

              other ->
                other
            end)

          {:ok, new_principals}
        else
          :no_match
        end
    end
  end
end
