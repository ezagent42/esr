defmodule Esr.Resource.Capability.UuidTranslator do
  @moduledoc """
  Translate cap strings between operator-readable form (with workspace
  names) and storage form (with workspace UUIDs).

  Caps shaped `<resource>:<scope>/<perm>` where `<resource>` is one
  of {"session", "workspace"} get their `<scope>` translated. Other
  cap strings (`user.manage`, `adapter.manage`, `runtime.deadletter`)
  pass through unchanged.

  ## Examples

      iex> # name → UUID (input direction)
      iex> UuidTranslator.name_to_uuid("session:esr-dev/create")
      {:ok, "session:7b9f3c1a-...../create"}

      iex> # UUID → name (output direction)
      iex> UuidTranslator.uuid_to_name("session:7b9f3c1a-...../create")
      "session:esr-dev/create"  # falls back to <UNKNOWN-...> if no match
  """

  alias Esr.Resource.Workspace.NameIndex

  @workspace_scoped_resources ~w(session workspace)

  @spec name_to_uuid(String.t()) :: {:ok, String.t()} | {:error, :unknown_workspace}
  def name_to_uuid(cap) do
    case parse(cap) do
      {:scoped, resource, scope, perm} when resource in @workspace_scoped_resources ->
        if uuid_shape?(scope) do
          # Scope is already a UUID — pass through unchanged.
          {:ok, cap}
        else
          # Treat scope as a workspace name; translate via NameIndex.
          case NameIndex.id_for_name(scope) do
            {:ok, id} -> {:ok, "#{resource}:#{id}/#{perm}"}
            :not_found -> {:error, :unknown_workspace}
          end
        end

      _ ->
        {:ok, cap}
    end
  end

  @spec uuid_to_name(String.t()) :: String.t()
  def uuid_to_name(cap) do
    case parse(cap) do
      {:scoped, resource, uuid, perm} when resource in @workspace_scoped_resources ->
        case NameIndex.name_for_id(uuid) do
          {:ok, name} ->
            "#{resource}:#{name}/#{perm}"

          :not_found ->
            # If <uuid> is actually already a name (didn't look UUID-shaped),
            # leave the cap as-is rather than wrapping in <UNKNOWN-...>.
            if uuid_shape?(uuid) do
              "#{resource}:<UNKNOWN-#{String.slice(uuid, 0..7)}>/#{perm}"
            else
              cap
            end
        end

      _ ->
        cap
    end
  end

  defp parse(cap) when is_binary(cap) do
    case String.split(cap, ":", parts: 2) do
      [resource, rest] ->
        case String.split(rest, "/", parts: 2) do
          [scope, perm] -> {:scoped, resource, scope, perm}
          _ -> {:flat, cap}
        end

      _ ->
        {:flat, cap}
    end
  end

  defp uuid_shape?(s) when is_binary(s) do
    Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/, s)
  end
end
