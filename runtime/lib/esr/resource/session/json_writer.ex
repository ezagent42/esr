defmodule Esr.Resource.Session.JsonWriter do
  @moduledoc """
  Atomic write of a `Session.Struct` to a `session.json` file.

  Uses `*.tmp` → rename to avoid torn state on crash. Creates parent
  directories as needed.
  """

  alias Esr.Resource.Session.Struct

  @spec write(String.t(), Struct.t()) :: :ok | {:error, term()}
  def write(path, %Struct{} = session) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- encode(session),
         tmp = path <> ".tmp",
         :ok <- File.write(tmp, json),
         :ok <- File.rename(tmp, path) do
      :ok
    end
  end

  defp encode(s) do
    map = %{
      "schema_version" => 1,
      "id" => s.id,
      "name" => s.name,
      "owner_user" => s.owner_user,
      "workspace_id" => s.workspace_id,
      "agents" => Enum.map(s.agents, &serialise_agent/1),
      "primary_agent" => s.primary_agent,
      "attached_chats" => Enum.map(s.attached_chats, &serialise_chat/1),
      "created_at" => s.created_at,
      "transient" => s.transient
    }

    Jason.encode(map, pretty: true)
  end

  defp serialise_agent(%{type: t, name: n, config: c}),
    do: %{"type" => t, "name" => n, "config" => c}

  defp serialise_chat(%{chat_id: cid, app_id: aid, attached_by: by, attached_at: at}),
    do: %{"chat_id" => cid, "app_id" => aid, "attached_by" => by, "attached_at" => at}
end
