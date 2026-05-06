defmodule Esr.Resource.Workspace.FileLoader do
  @moduledoc """
  Read a workspace.json file from disk and return an
  `%Esr.Resource.Workspace.Struct{}` or a structured error.

  Used by both the ESR-bound discovery path (walks
  `$ESRD_HOME/<inst>/workspaces/`) and the repo-bound path (walks
  `registered_repos.yaml` paths). Caller passes the `location:` kwarg
  so the loader knows which validity rules apply (e.g. ESR-bound
  names must equal basename; repo-bound transient is forbidden).
  """

  alias Esr.Resource.Workspace.Struct

  @uuid_re ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

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
