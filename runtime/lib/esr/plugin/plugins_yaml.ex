defmodule Esr.Plugin.PluginsYaml do
  @moduledoc """
  Atomically read + write `<runtime_home>/plugins.yaml` — enabled list
  only.

  Per yaml-layout-v2 (spec § 4.2): `plugins.yaml` is an **enabled-only**
  registry. Plugin-specific configuration lives under
  `plugins/<name>/config.yaml` (handled by `Esr.Plugin.Config`).

  Reading a `plugins.yaml` that contains `:config` or any other
  top-level key besides `enabled` **raises**. This is hard cutover: no
  legacy fallback, no auto-migration. Operators that hit the raise edit
  the file (delete the `:config` block) and restart.

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

  Persists with an explicit `enabled:` key.
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
    path = Esr.Paths.plugins_yaml()

    case File.read(path) do
      {:ok, content} ->
        case YamlElixir.read_from_string(content) do
          {:ok, %{"enabled" => list}} when is_list(list) ->
            Enum.filter(list, &is_binary/1)

          {:ok, nil} ->
            []

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
