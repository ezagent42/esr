defmodule Esr.Resource.Session.FileLoader do
  @moduledoc """
  Read a session.json file from disk and return an
  `%Esr.Resource.Session.Struct{}` or a structured error.

  Phase 7 (2026-05-10) hardcut: schema_version = 2. session.json now
  carries `agent_ids:` (UUID array) instead of an embedded `agents:[]`
  array; the per-instance records live in sibling files at
  `sessions/<sid>/agents/<instance_uuid>.json`.

  PR-3 (URI identity migration, 2026-05-12) adds `populate_uri_store/0`
  to subsume the boot-time scan that used to live in
  `Esr.Resource.Session.Registry.init/1`. The Registry module is
  deleted; this loader (invoked by `Esr.Resource.Session.Loader` Task
  at app boot) is the single boot-time entry point.

  URI store layout (per session):
    - canonical: esr://localhost/sessions/<uuid> → %Session.Struct{}
  """

  require Logger

  alias Esr.Paths
  alias Esr.Resource.Session.Struct

  @uuid_re ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  @spec load(String.t(), keyword()) :: {:ok, Struct.t()} | {:error, term()}
  def load(path, _opts) do
    with {:ok, body} <- read_file(path),
         {:ok, doc} <- decode_json(body),
         :ok <- check_schema_version(doc),
         :ok <- check_required(doc, ["id", "name", "owner_user", "workspace_id"]),
         :ok <- check_nonempty(doc, "owner_user"),
         :ok <- check_uuid(doc["id"]) do
      {:ok, build_struct(doc)}
    end
  end

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

  defp check_schema_version(%{"schema_version" => 2}), do: :ok
  defp check_schema_version(%{"schema_version" => v}), do: {:error, {:bad_schema_version, v}}
  defp check_schema_version(_), do: {:error, {:bad_schema_version, nil}}

  defp check_required(doc, fields) do
    case Enum.find(fields, fn f -> not Map.has_key?(doc, f) or doc[f] == nil end) do
      nil -> :ok
      missing -> {:error, {:missing_field, missing}}
    end
  end

  defp check_nonempty(doc, field) do
    case Map.get(doc, field) do
      v when is_binary(v) and v != "" -> :ok
      _ -> {:error, {:missing_field, field}}
    end
  end

  defp check_uuid(uuid) when is_binary(uuid) do
    if Regex.match?(@uuid_re, uuid), do: :ok, else: {:error, {:bad_uuid, uuid}}
  end

  defp check_uuid(other), do: {:error, {:bad_uuid, other}}

  defp build_struct(doc) do
    %Struct{
      id: doc["id"],
      name: doc["name"],
      owner_user: doc["owner_user"],
      workspace_id: doc["workspace_id"],
      agent_ids: doc["agent_ids"] || [],
      primary_agent: doc["primary_agent"],
      attached_chats: Enum.map(doc["attached_chats"] || [], &normalize_chat/1),
      created_at: doc["created_at"],
      transient: doc["transient"] || false
    }
  end

  defp normalize_chat(%{"chat_id" => cid, "app_id" => aid, "attached_by" => by, "attached_at" => at}),
    do: %{chat_id: cid, app_id: aid, attached_by: by, attached_at: at}

  # ──────────────────────────────────────────────────────────────────
  # Boot-time URI store populator (PR-3)
  # ──────────────────────────────────────────────────────────────────

  @doc """
  Scan `Esr.Paths.sessions_dir/0` for all session.json files, wipe the
  URI store's `:session` rows (and any aliases pointing at them), then
  rewrite a canonical `esr://localhost/sessions/<uuid>` entity row for
  each session found on disk.

  Returns `:ok` on success or `{:error, reason}` for catastrophic
  failures. Individual parse failures are logged + skipped (matches
  old Registry.scan_sessions_dir behaviour).
  """
  @spec populate_uri_store() :: :ok | {:error, term()}
  def populate_uri_store do
    if uri_store_alive?() do
      sessions = scan_sessions_dir()
      _ = Esr.Uri.Store.delete_all_by_kind(:session)

      Enum.each(sessions, fn s ->
        canonical = "esr://localhost/sessions/" <> s.id
        :ok = Esr.Uri.put_entity(canonical, :session, s)
      end)

      Logger.info("sessions: loaded #{length(sessions)} sessions into URI store")
      :ok
    else
      Logger.warning("sessions: Esr.Uri.Store not running; skipping URI store population")
      :ok
    end
  end

  defp uri_store_alive? do
    case Process.whereis(Esr.Uri.Store) do
      pid when is_pid(pid) -> true
      _ -> false
    end
  end

  defp scan_sessions_dir do
    base = Paths.sessions_dir()

    if File.exists?(base) do
      base
      |> File.ls!()
      |> Enum.flat_map(fn entry ->
        path = Path.join([base, entry, "session.json"])

        case load(path, []) do
          {:ok, s} ->
            [s]

          {:error, :file_missing} ->
            []

          {:error, reason} ->
            Logger.warning("sessions: skipping #{path} (#{inspect(reason)})")
            []
        end
      end)
    else
      []
    end
  end
end
