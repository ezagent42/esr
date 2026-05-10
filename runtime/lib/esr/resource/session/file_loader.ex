defmodule Esr.Resource.Session.FileLoader do
  @moduledoc """
  Read a session.json file from disk and return an
  `%Esr.Resource.Session.Struct{}` or a structured error.

  Phase 7 (2026-05-10) hardcut: schema_version = 2. session.json now
  carries `agent_ids:` (UUID array) instead of an embedded `agents:[]`
  array; the per-instance records live in sibling files at
  `sessions/<sid>/agents/<instance_uuid>.json`.
  """

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
end
