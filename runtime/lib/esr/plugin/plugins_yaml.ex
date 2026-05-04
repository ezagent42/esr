defmodule Esr.Plugin.PluginsYaml do
  @moduledoc """
  Atomically read + write `<runtime_home>/plugins.yaml`.

  Track 0 Task 0.6 (admin commands `/plugin enable`, `/plugin disable`).
  Companion to `Esr.Plugin.EnabledList` which only reads — this module
  also writes, so that `enable/1` and `disable/1` can persist operator
  changes between restarts.

  Atomicity: write happens via `tmp_path → rename`. A crash mid-rename
  leaves either the old or the new file in place, never a half-written
  one (POSIX rename semantics).
  """

  alias Esr.Plugin.EnabledList

  @doc """
  Return the current enabled list from disk. Convenience wrapper over
  `EnabledList.read/1` that uses the canonical path.
  """
  @spec read() :: [String.t()]
  def read do
    EnabledList.read(Esr.Paths.plugins_yaml())
  end

  @doc """
  Add `name` to the enabled list and persist. Idempotent —
  no-op if `name` is already enabled.

  Persists with an explicit `enabled:` key (never the legacy
  fallback) so a subsequent `read/0` after `disable/1` returns
  exactly what was written.
  """
  @spec enable(String.t()) :: :ok | {:error, term()}
  def enable(name) when is_binary(name) do
    current = read_explicit()
    next = (current ++ [name]) |> Enum.uniq()
    write(next)
  end

  @doc """
  Remove `name` from the enabled list and persist. Idempotent —
  no-op if `name` is already disabled.
  """
  @spec disable(String.t()) :: :ok | {:error, term()}
  def disable(name) when is_binary(name) do
    current = read_explicit()
    next = Enum.reject(current, &(&1 == name))
    write(next)
  end

  # Read whatever is on disk; if the file is missing, treat as empty
  # (NOT the legacy default) so enable/disable produce a deterministic
  # config rather than overwriting an absent file with the legacy list.
  defp read_explicit do
    case File.read(Esr.Paths.plugins_yaml()) do
      {:ok, content} ->
        case YamlElixir.read_from_string(content) do
          {:ok, %{"enabled" => list}} when is_list(list) ->
            Enum.filter(list, &is_binary/1)

          _ ->
            []
        end

      {:error, :enoent} ->
        []

      {:error, _} ->
        []
    end
  end

  defp write(list) do
    path = Esr.Paths.plugins_yaml()
    tmp = path <> ".tmp"

    items = Enum.map_join(list, "", fn name -> "  - #{name}\n" end)

    body =
      case items do
        "" -> "enabled: []\n"
        _ -> "enabled:\n" <> items
      end

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, body),
         :ok <- File.rename(tmp, path) do
      :ok
    end
  end
end
