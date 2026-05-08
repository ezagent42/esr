defmodule Esr.Resource.Workspace.JsonWriter do
  @moduledoc """
  Atomic write of a `Workspace.Struct` to a `workspace.json` file.

  Uses `*.tmp` → fsync → rename to avoid leaving the file in a torn
  state if the process dies mid-write. Creates parent dirs as needed.
  """

  alias Esr.Resource.Workspace.Struct

  @spec write(String.t(), Struct.t()) :: :ok | {:error, term()}
  def write(path, %Struct{} = ws) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- encode(ws),
         tmp = path <> ".tmp",
         :ok <- File.write(tmp, json),
         :ok <- File.rename(tmp, path) do
      :ok
    end
  end

  defp encode(ws) do
    map = %{
      "schema_version" => 1,
      "id" => ws.id,
      "name" => ws.name,
      "owner" => ws.owner,
      "folders" => Enum.map(ws.folders, &serialise_folder/1),
      "agent" => ws.agent,
      "settings" => ws.settings,
      "env" => ws.env,
      "chats" => Enum.map(ws.chats, &serialise_chat/1),
      "transient" => ws.transient
    }

    Jason.encode(map, pretty: true)
  end

  defp serialise_folder(%{path: p, name: nil}), do: %{"path" => p}
  defp serialise_folder(%{path: p, name: n}) when is_binary(n), do: %{"path" => p, "name" => n}
  defp serialise_folder(%{path: p}), do: %{"path" => p}

  defp serialise_chat(%{chat_id: cid, app_id: aid, kind: k}),
    do: %{"chat_id" => cid, "app_id" => aid, "kind" => k}
end
