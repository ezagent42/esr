defmodule Esr.Resource.Workspace.FileLoader do
  @moduledoc """
  Read workspace.json file(s) from disk and either:

    1. Return a single `%Esr.Resource.Workspace.Struct{}` (`load/2` —
       still used by `/workspace import-repo` and other callers that
       parse a single file ad-hoc).

    2. Walk both `Esr.Paths.workspaces_dir/0` (ESR-bound) and
       `Esr.Paths.registered_repos_yaml/0` (repo-bound), then populate
       the URI store with canonical workspace rows + by-name +
       by-chat aliases (`populate_uri_store/0`).

  PR-2 (URI identity migration, 2026-05-12) added `populate_uri_store/0`
  to subsume the boot-time scan that used to live in
  `Esr.Resource.Workspace.Registry.init/1`. The Registry module is
  deleted; this loader (invoked by `Esr.Resource.Workspace.Loader`
  Task at app boot) is the single boot-time entry point.

  URI store layout (per workspace):
    - canonical: esr://localhost/workspaces/<uuid>           → %Workspace.Struct{}
    - by-name:   esr://localhost/workspaces/by-name/<name>   → alias
    - by-chat:   esr://localhost/workspaces/by-chat/<cid>/<aid> → alias  (one per bound chat)
  """

  @behaviour Esr.Role.Control
  require Logger

  alias Esr.Paths
  alias Esr.Resource.Workspace.{RepoRegistry, Struct}

  @uuid_re ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  # ──────────────────────────────────────────────────────────────────
  # Single-file load (unchanged from pre-PR-2 — keeps callers like
  # /workspace import-repo working without churn)
  # ──────────────────────────────────────────────────────────────────

  @spec load(String.t(), location: Struct.location()) ::
          {:ok, Struct.t()} | {:error, term()}
  def load(path, opts) do
    location = Keyword.fetch!(opts, :location)

    with {:ok, body} <- read_file(path),
         {:ok, doc} <- decode_json(body),
         :ok <- check_schema_version(doc),
         :ok <- check_required(doc, ["id", "name", "owner"]),
         :ok <- check_uuid(doc["id"]),
         :ok <- check_location_invariants(doc, location) do
      {:ok, build_struct(doc, location)}
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # Boot-time URI store populator (PR-2)
  # ──────────────────────────────────────────────────────────────────

  @doc """
  Scan disk for all known workspaces (ESR-bound + repo-bound), wipe
  the URI store's `:workspace` rows + their aliases, and rewrite them
  fresh.

  Returns `:ok` on success, `{:error, {:duplicate_uuid, id, locations}}`
  if two different workspace.json files share the same uuid. On parse
  failure of an individual file, the file is skipped with a warning
  log (matches old Registry.scan_* behaviour).
  """
  @spec populate_uri_store() :: :ok | {:error, term()}
  def populate_uri_store do
    if uri_store_alive?() do
      esr_bound = scan_esr_bound()
      repo_bound = scan_repo_bound()
      all = esr_bound ++ repo_bound

      case duplicate_uuid(all) do
        nil ->
          _ = Esr.Uri.Store.delete_all_by_kind(:workspace)

          Enum.each(all, fn ws ->
            canonical = "esr://localhost/workspaces/" <> ws.id
            :ok = Esr.Uri.put_entity(canonical, :workspace, ws)
            _ = Esr.Uri.alias(canonical, "esr://localhost/workspaces/by-name/" <> ws.name)

            Enum.each(ws.chats || [], fn chat ->
              cid = Map.get(chat, :chat_id) || Map.get(chat, "chat_id")
              aid = Map.get(chat, :app_id) || Map.get(chat, "app_id")

              if is_binary(cid) and is_binary(aid) do
                _ = Esr.Uri.alias(canonical, "esr://localhost/workspaces/by-chat/#{cid}/#{aid}")
              end
            end)
          end)

          Logger.info("workspaces: loaded #{length(all)} workspaces into URI store")
          :ok

        {dup_id, dup_locations} ->
          Logger.error(
            "workspaces: duplicate uuid #{dup_id} at #{inspect(dup_locations)}; refusing to load"
          )

          {:error, {:duplicate_uuid, dup_id, dup_locations}}
      end
    else
      Logger.warning("workspaces: Esr.Uri.Store not running; skipping URI store population")
      :ok
    end
  end

  defp uri_store_alive? do
    case Process.whereis(Esr.Uri.Store) do
      pid when is_pid(pid) -> true
      _ -> false
    end
  end

  defp scan_esr_bound do
    base = Paths.workspaces_dir()

    if File.exists?(base) do
      base
      |> File.ls!()
      |> Enum.flat_map(fn name ->
        dir = Path.join(base, name)
        path = Path.join(dir, "workspace.json")

        case load(path, location: {:esr_bound, dir}) do
          {:ok, ws} ->
            [ws]

          {:error, reason} ->
            Logger.warning("workspaces: skipping #{path} (#{inspect(reason)})")
            []
        end
      end)
    else
      []
    end
  end

  defp scan_repo_bound do
    case RepoRegistry.load(Paths.registered_repos_yaml()) do
      {:ok, repos} ->
        Enum.flat_map(repos, fn entry ->
          path = Paths.workspace_json_repo(entry.path)

          case load(path, location: {:repo_bound, entry.path}) do
            {:ok, ws} ->
              [ws]

            {:error, reason} ->
              Logger.warning("workspaces: skipping repo #{entry.path} (#{inspect(reason)})")
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp duplicate_uuid(workspaces) do
    workspaces
    |> Enum.group_by(& &1.id)
    |> Enum.find(fn {_id, list} -> length(list) > 1 end)
    |> case do
      nil -> nil
      {id, list} -> {id, Enum.map(list, & &1.location)}
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # Private helpers
  # ──────────────────────────────────────────────────────────────────

  defp read_file(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, :enoent} -> {:error, :file_missing}
      {:error, reason} -> {:error, {:file_read_failed, reason}}
    end
  end

  defp decode_json(body) do
    case Jason.decode(body) do
      {:ok, %{} = doc} -> {:ok, doc}
      {:ok, _} -> {:error, :json_not_object}
      {:error, _} -> {:error, :json_decode_failed}
    end
  end

  defp check_schema_version(%{"schema_version" => 1}), do: :ok
  defp check_schema_version(%{"schema_version" => v}), do: {:error, {:bad_schema_version, v}}
  defp check_schema_version(_), do: {:error, {:bad_schema_version, nil}}

  defp check_required(doc, fields) do
    case Enum.find(fields, fn f -> not Map.has_key?(doc, f) or doc[f] == nil end) do
      nil -> :ok
      missing -> {:error, {:missing_field, missing}}
    end
  end

  defp check_uuid(uuid) when is_binary(uuid) do
    if Regex.match?(@uuid_re, uuid), do: :ok, else: {:error, {:bad_uuid, uuid}}
  end

  defp check_uuid(other), do: {:error, {:bad_uuid, other}}

  defp check_location_invariants(doc, {:esr_bound, dir}) do
    expected = Path.basename(dir)

    cond do
      doc["name"] != expected -> {:error, {:name_mismatch, doc["name"], expected}}
      true -> :ok
    end
  end

  defp check_location_invariants(doc, {:repo_bound, _repo_path}) do
    cond do
      doc["transient"] == true -> {:error, :transient_repo_bound_forbidden}
      true -> :ok
    end
  end

  defp build_struct(doc, location) do
    %Struct{
      id: doc["id"],
      name: doc["name"],
      owner: doc["owner"],
      folders: Enum.map(doc["folders"] || [], &normalize_folder/1),
      agent: doc["agent"] || "cc",
      settings: doc["settings"] || %{},
      env: doc["env"] || %{},
      chats: Enum.map(doc["chats"] || [], &normalize_chat/1),
      transient: doc["transient"] || false,
      location: location
    }
  end

  defp normalize_folder(%{"path" => p} = m), do: %{path: p, name: m["name"]}

  defp normalize_chat(%{"chat_id" => cid, "app_id" => aid} = m) do
    base = %{chat_id: cid, app_id: aid}
    if m["kind"], do: Map.put(base, :kind, m["kind"]), else: Map.put(base, :kind, "dm")
  end
end
