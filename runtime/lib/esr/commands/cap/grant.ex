defmodule Esr.Commands.Cap.Grant do
  @moduledoc """
  `Esr.Commands.Cap.Grant` — adds a permission to a principal's
  capability list in `capabilities.yaml` (dev-prod-isolation spec §6.4
  Cap.Grant bullet, plan DI-10 Task 23).

  Called by `Esr.Admin.Dispatcher` inside a `Task.start` when a
  `grant`-kind command reaches the front of the queue. Pure function
  module (no GenServer).

  ## Flow

    1. Read `capabilities.yaml` via `YamlElixir`. Missing file starts
       from the canonical `%{"principals" => []}` skeleton.
    2. Locate the principal entry by `id`. If absent, append a fresh
       entry with `kind: "feishu_user"` (default — matches the spec's
       §5 schema example) and empty `capabilities: []`.
    3. Append the permission to that principal's `capabilities` list
       when it isn't already held (idempotent).
    4. Write back via `Esr.Yaml.Writer`. The file-level
       `Esr.Resource.Capability.Watcher` (fs_event) will observe the change
       and call `FileLoader.load/1`, which atomically swaps the in-
       memory ETS snapshot — **no direct `Grants` mutation is done
       here** (spec §6.4 requirement: Admin writes the file, Watcher
       reloads ETS).

  ## Result

    * `{:ok, %{"target_principal_id" => id, "permission" => perm, "action" => "granted"}}`
    * `{:error, %{"type" => "invalid_args", ...}}` — malformed command.
  """

  use Esr.Commands.Meta

  command :cap_grant do
    slash         "/cap:grant"
    category      "Capabilities"
    description   "授权 cap 给用户；session cap 仅接受 UUID 形式"
    permission    "cap.manage"
    requires_user_binding      false
    requires_workspace_binding false

    arg :target_principal_id, required: true, doc: "principal being granted to (the operation target)"
    arg :permission,          required: true, doc: "permission 字符串（session cap 必须是 UUID 形式）"

    error :reserved_principal_id,    "'system:bootstrap' is a reserved sentinel; cannot be granted caps"
    error :session_cap_requires_uuid, "%{detail}"
    error :unknown_workspace,         "no workspace found in capability scope: %{permission}"
    error :invalid_args,              "grant requires args.target_principal_id and args.permission (non-empty strings)"
    error :write_failed,              "%{detail}"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"target_principal_id" => "system:bootstrap"}}) do
    # 2026-05-09 zero-config bootstrap (spec § 3.1, D1): the reserved
    # sentinel principal_id cannot be granted caps via cap_grant — that
    # would defeat the whole "sentinel can't be poisoned" property the
    # slash-handler bypass relies on. Mirrors the FileLoader rejection.
    Render.error(__MODULE__.command_meta(), :reserved_principal_id)
  end

  def execute(%{"args" => %{"target_principal_id" => pid, "permission" => perm}})
      when is_binary(pid) and pid != "" and is_binary(perm) and perm != "" do
    with :ok <- validate_session_cap(perm),
         {:ok, translated_perm} <- Esr.Resource.Capability.UuidTranslator.name_to_uuid(perm) do
      do_grant(pid, translated_perm)
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

  defp do_grant(pid, perm) do
    path = Esr.Paths.capabilities_yaml()

    doc = read_or_empty(path)
    principals = Map.get(doc, "principals") || []

    updated_principals = upsert_grant(principals, pid, perm)

    updated_doc = Map.put(doc, "principals", updated_principals)

    case Esr.Yaml.Writer.write(path, updated_doc) do
      :ok ->
        {:ok,
         %{
           "target_principal_id" => pid,
           "permission" => perm,
           "action" => "granted"
         }}

      {:error, reason} ->
        Render.error(__MODULE__.command_meta(), :write_failed, %{detail: inspect(reason)})
    end
  end

  # Missing / unreadable file → canonical empty skeleton. Matches the
  # spec §5 schema shape so later writes stay valid YAML.
  defp read_or_empty(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{} = m} -> m
      _ -> %{"principals" => []}
    end
  end

  # Locate the principal by id, append `perm` to `capabilities` unless
  # already held. When the principal isn't present, append a new entry
  # with the default `feishu_user` kind + `[perm]`.
  defp upsert_grant(principals, pid, perm) when is_list(principals) do
    case Enum.split_with(principals, fn p -> is_map(p) and p["id"] == pid end) do
      {[], others} ->
        others ++
          [
            %{
              "id" => pid,
              "kind" => "feishu_user",
              "capabilities" => [perm]
            }
          ]

      {[existing | _], others} ->
        caps = Map.get(existing, "capabilities") || []

        new_caps =
          if perm in caps, do: caps, else: caps ++ [perm]

        updated = Map.put(existing, "capabilities", new_caps)
        # Preserve original ordering: re-insert in-place.
        place_back(principals, pid, updated, others)
    end
  end

  defp upsert_grant(_other, pid, perm) do
    # Malformed principals list — start fresh with just this entry.
    [%{"id" => pid, "kind" => "feishu_user", "capabilities" => [perm]}]
  end

  # Rebuild the principals list keeping the original index of the
  # updated entry (so grant/revoke don't reshuffle the yaml on every
  # edit — makes diffs operator-readable).
  defp place_back(original, pid, updated, _others) do
    Enum.map(original, fn
      p when is_map(p) ->
        if p["id"] == pid, do: updated, else: p

      other ->
        other
    end)
  end
end
