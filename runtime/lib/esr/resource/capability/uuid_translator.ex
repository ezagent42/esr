defmodule Esr.Resource.Capability.UuidTranslator do
  @moduledoc """
  Translate cap strings between operator-readable form (with workspace
  names) and storage form (with workspace UUIDs).

  Caps shaped `<resource>:<scope>/<perm>` where `<resource>` is
  `"workspace"` get their `<scope>` translated via NameIndex. Other
  cap strings (`user.manage`, `adapter.manage`, `runtime.deadletter`)
  pass through unchanged.

  ## Session caps: UUID-only contract (Phase 5, spec D2 + D5)

  Session caps **always require a UUID at input**. Name input is
  rejected with `{:error, {:session_name_in_cap, msg}}` by
  `validate_session_cap_input/1`, which must be called at every command
  entry point (Grant, Revoke, etc.) before any translation.

  Output rendering uses `render_cap_for_display/1` which translates
  `session:<uuid>/...` → `session:<name>/... (uuid: <uuid>)` when the
  session is found, or `session:<UNKNOWN-prefix>/...` for orphan UUIDs.

  ## Examples

      iex> # workspace name → UUID (input direction)
      iex> UuidTranslator.name_to_uuid("workspace:esr-dev/read")
      {:ok, "workspace:7b9f3c1a-...../read"}

      iex> # session cap: UUID passthrough
      iex> UuidTranslator.name_to_uuid("session:a1b2c3d4-.../attach")
      {:ok, "session:a1b2c3d4-.../attach"}

      iex> # UUID → name (output direction)
      iex> UuidTranslator.uuid_to_name("workspace:7b9f3c1a-...../read")
      "workspace:esr-dev/read"  # falls back to <UNKNOWN-...> if no match
  """

  alias Esr.Resource.Workspace.NameIndex

  # Only workspace caps accept name input at the name_to_uuid level.
  # Session caps: UUID-only (spec D2, D5). Name input is rejected upstream
  # by validate_session_cap_input/1.
  @workspace_scoped_resources ~w(workspace)

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

  @doc """
  Validate that a cap string containing `session:<x>/...` uses a UUID v4 for
  `<x>`. Name input is explicitly rejected for session caps (spec D2, D5).

  Non-session caps pass through as `:ok`.
  """
  @spec validate_session_cap_input(String.t()) ::
          :ok | {:error, {:session_name_in_cap, String.t()}}
  def validate_session_cap_input(cap) when is_binary(cap) do
    case Regex.run(~r{^session:([^/]+)/}, cap) do
      [_, value] ->
        if uuid_shape?(value) do
          :ok
        else
          {:error,
           {:session_name_in_cap,
            "session caps require UUID; name input is not accepted (got \"#{value}\")"}}
        end

      _ ->
        :ok
    end
  end

  @doc """
  Translate a session UUID to its human-readable name for **output rendering only**.

  This function is intentionally NOT called at input time. Session caps reject
  names entirely at input (use `validate_session_cap_input/1` at every entry
  point instead).

  Returns `{:ok, name}` when the session is found, or `{:error, :not_found}`
  when the UUID is not known (orphan cap — session was deleted).
  """
  @spec session_uuid_to_name(String.t(), map()) ::
          {:ok, String.t()} | {:error, :not_found}
  def session_uuid_to_name(uuid, _context) when is_binary(uuid) do
    case Esr.Resource.Session.Registry.get_by_id(uuid) do
      {:ok, session} -> {:ok, session.name}
      :not_found -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  @doc """
  Render a cap string for human-readable output.

  * `workspace:<uuid>/...` → `workspace:<name>/...` (via NameIndex; unchanged if not found)
  * `session:<uuid>/...` → `session:<name>/... (uuid: <uuid>)` if session found,
    else `session:<UNKNOWN-<8-char-prefix>>/...`
  * All other caps → unchanged.
  """
  @spec render_cap_for_display(String.t()) :: String.t()
  def render_cap_for_display(cap) when is_binary(cap) do
    case parse(cap) do
      {:scoped, "session", uuid, perm} ->
        if uuid_shape?(uuid) do
          case session_uuid_to_name(uuid, %{}) do
            {:ok, name} ->
              "session:#{name}/#{perm} (uuid: #{uuid})"

            {:error, :not_found} ->
              "session:<UNKNOWN-#{String.slice(uuid, 0, 8)}>/#{perm}"
          end
        else
          cap
        end

      {:scoped, "workspace", uuid, perm} ->
        if uuid_shape?(uuid) do
          case NameIndex.name_for_id(uuid) do
            {:ok, name} -> "workspace:#{name}/#{perm}"
            :not_found -> "workspace:<UNKNOWN-#{String.slice(uuid, 0, 8)}>/#{perm}"
          end
        else
          cap
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
