defmodule Esr.Entity.Agent.InstanceJson do
  @moduledoc """
  Atomic read/write of `%Esr.Entity.Agent.Instance{}` records to per-
  instance JSON files at `sessions/<sid>/agents/<instance_uuid>.json`.

  Phase 7 (2026-05-10): introduced when the `agents:[]` array embedded
  in session.json was split into one file per instance. Validated
  against `priv/schemas/agent_instance.v2.json`. Multi-session-per-
  instance attaches/detaches rewrite the SAME file (any one of the
  instance's `session_ids` directories may host the canonical copy —
  see `find_canonical_path/2`).
  """

  alias Esr.Entity.Agent.Instance
  alias Esr.Paths

  @uuid_re ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  @spec write(String.t(), Instance.t()) :: :ok | {:error, term()}
  def write(path, %Instance{} = inst) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- encode(inst),
         tmp = path <> ".tmp",
         :ok <- File.write(tmp, json),
         :ok <- File.rename(tmp, path) do
      :ok
    end
  end

  @spec load(String.t()) :: {:ok, Instance.t()} | {:error, term()}
  def load(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{} = doc} <- Jason.decode(body),
         :ok <- check_schema_version(doc),
         :ok <- check_required(doc),
         :ok <- check_uuid(doc["id"]),
         :ok <- check_session_ids(doc["session_ids"]) do
      {:ok, build_struct(doc)}
    else
      {:error, _} = err -> err
      err -> {:error, err}
    end
  end

  @doc """
  List every `<uuid>.json` file in `sessions/<sid>/agents/`. Returns a
  list of absolute paths. Returns `[]` if the dir doesn't exist.
  """
  @spec list_paths_for_session(String.t()) :: [String.t()]
  def list_paths_for_session(session_id) when is_binary(session_id) do
    dir = Paths.session_agents_dir(session_id)

    if File.exists?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.map(&Path.join(dir, &1))
    else
      []
    end
  end

  @doc """
  Find the canonical on-disk path for an instance. The instance is
  written to its FIRST session_id's agents/ directory; pass the
  instance's `session_ids` to locate it.
  """
  @spec canonical_path(Instance.t()) :: String.t()
  def canonical_path(%Instance{id: instance_id, session_ids: [sid | _]})
      when is_binary(instance_id) and is_binary(sid) do
    Paths.agent_instance_json(sid, instance_id)
  end

  defp encode(%Instance{} = inst) do
    map = %{
      "schema_version" => 2,
      "id" => inst.id,
      "session_ids" => inst.session_ids,
      "type" => inst.type,
      "name" => inst.name,
      "config" => inst.config || %{},
      "created_at" => inst.created_at
    }

    map =
      case inst.actor_ids do
        %{cc: cc, pty: pty} when is_binary(cc) and is_binary(pty) ->
          Map.put(map, "actor_ids", %{"cc" => cc, "pty" => pty})

        _ ->
          map
      end

    Jason.encode(map, pretty: true)
  end

  defp check_schema_version(%{"schema_version" => 2}), do: :ok
  defp check_schema_version(%{"schema_version" => v}), do: {:error, {:bad_schema_version, v}}
  defp check_schema_version(_), do: {:error, {:bad_schema_version, nil}}

  defp check_required(doc) do
    fields = ["id", "session_ids", "type", "name", "config", "created_at"]

    case Enum.find(fields, fn f -> not Map.has_key?(doc, f) or doc[f] == nil end) do
      nil -> :ok
      missing -> {:error, {:missing_field, missing}}
    end
  end

  defp check_uuid(uuid) when is_binary(uuid) do
    if Regex.match?(@uuid_re, uuid), do: :ok, else: {:error, {:bad_uuid, uuid}}
  end

  defp check_uuid(other), do: {:error, {:bad_uuid, other}}

  defp check_session_ids(ids) when is_list(ids) and ids != [] do
    case Enum.find(ids, fn s -> not is_binary(s) or not Regex.match?(@uuid_re, s) end) do
      nil -> :ok
      bad -> {:error, {:bad_session_id, bad}}
    end
  end

  defp check_session_ids(_), do: {:error, {:bad_session_ids, :empty_or_not_list}}

  defp build_struct(doc) do
    actor_ids =
      case doc["actor_ids"] do
        %{"cc" => cc, "pty" => pty} -> %{cc: cc, pty: pty}
        _ -> nil
      end

    %Instance{
      id: doc["id"],
      session_ids: doc["session_ids"],
      type: doc["type"],
      name: doc["name"],
      config: doc["config"] || %{},
      created_at: doc["created_at"],
      actor_ids: actor_ids
    }
  end
end
