defmodule Esr.Admin.Commands.Cap.Grant do
  @moduledoc """
  `Esr.Admin.Commands.Cap.Grant` — adds a permission to a principal's
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

    * `{:ok, %{"principal_id" => id, "permission" => perm, "action" => "granted"}}`
    * `{:error, %{"type" => "invalid_args", ...}}` — malformed command.
  """

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"principal_id" => pid, "permission" => perm}})
      when is_binary(pid) and pid != "" and is_binary(perm) and perm != "" do
    path = Esr.Paths.capabilities_yaml()

    doc = read_or_empty(path)
    principals = Map.get(doc, "principals") || []

    updated_principals = upsert_grant(principals, pid, perm)

    updated_doc = Map.put(doc, "principals", updated_principals)

    case Esr.Yaml.Writer.write(path, updated_doc) do
      :ok ->
        {:ok,
         %{
           "principal_id" => pid,
           "permission" => perm,
           "action" => "granted"
         }}

      {:error, reason} ->
        {:error, %{"type" => "write_failed", "detail" => inspect(reason)}}
    end
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" =>
         "grant requires args.principal_id and args.permission (non-empty strings)"
     }}
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

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
