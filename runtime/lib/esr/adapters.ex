defmodule Esr.Adapters do
  @moduledoc """
  Library module — adapter-instance storage under
  `$ESRD_HOME/<inst>/adapters/<name>/config.yaml` (yaml-layout-v2 spec
  § 4.3).

  Replaces the monolithic `<inst>/adapters.yaml` of v1. Each adapter
  instance is its own directory, mirroring the existing
  `users/<uuid>/`, `workspaces/<name>/`, `sessions/<name>/` convention.

  ## File contract

      adapters/<name>/config.yaml:
        type: feishu
        config:
          app_id: cli_xxx
          app_secret: xxx

  Top-level keys: `type` (required string), `config` (required map).
  Adapter `name` = directory basename.

  ## Reserved names

  Any directory under `adapters/` whose basename starts with `_` is
  ignored by `list/1`. `_disabled/` is the canonical use; the prefix
  rule covers any future reserved name and any operator-created folder
  meant to be invisible to the runtime. `add/4` validates and rejects
  user-supplied names starting with `_`.

  ## Atomicity

  - `add/4` writes via `Esr.Yaml.Writer.write_atomic/2` (tmp+rename).
  - `disable/2` and `enable/2` use `File.rename/2` — POSIX `rename(2)`
    is atomic on the same filesystem.
  - `remove/2` is `File.rm_rf!/1`; atomicity not relevant.

  ## opts

    * `:home` — override `Esr.Paths.runtime_home/0` (test seam).
  """

  @type instance_name :: String.t()
  @type adapter :: %{name: instance_name(), type: String.t(), config: map()}

  # Validation pattern for user-supplied instance names. Mirrors the one
  # already used by `Esr.Commands.Adapter.Rename`.
  @name_pattern ~r/^[A-Za-z][A-Za-z0-9_-]{0,62}$/

  @doc """
  Scan `adapters/*/config.yaml` and return one map per active instance.
  Skips any directory whose basename starts with `_` (covers `_disabled`
  and any operator-created reserved folder).
  """
  @spec list(opts :: keyword()) :: [adapter()]
  def list(opts \\ []) do
    adapters_root(opts)
    |> list_dir_entries()
    |> Enum.reject(&String.starts_with?(&1, "_"))
    |> Enum.sort()
    |> Enum.flat_map(fn name -> read_one(adapters_root(opts), name) end)
  end

  @doc """
  Same as `list/1` but reads from `adapters/_disabled/`.
  """
  @spec list_disabled(opts :: keyword()) :: [adapter()]
  def list_disabled(opts \\ []) do
    Path.join(adapters_root(opts), "_disabled")
    |> list_dir_entries()
    |> Enum.sort()
    |> Enum.flat_map(fn name -> read_one(Path.join(adapters_root(opts), "_disabled"), name) end)
  end

  @doc """
  Fetch one active instance by name. Returns `{:error, :not_found}` if
  the directory or its `config.yaml` is absent / unreadable.
  """
  @spec get(instance_name(), keyword()) :: {:ok, adapter()} | {:error, :not_found}
  def get(name, opts \\ []) when is_binary(name) do
    case read_one(adapters_root(opts), name) do
      [adapter] -> {:ok, adapter}
      [] -> {:error, :not_found}
    end
  end

  @doc "True iff `adapters/<name>/config.yaml` exists and parses."
  @spec exists?(instance_name(), keyword()) :: boolean()
  def exists?(name, opts \\ []) when is_binary(name) do
    File.exists?(Path.join([adapters_root(opts), name, "config.yaml"]))
  end

  @doc "True iff `adapters/_disabled/<name>/config.yaml` exists."
  @spec disabled?(instance_name(), keyword()) :: boolean()
  def disabled?(name, opts \\ []) when is_binary(name) do
    File.exists?(Path.join([adapters_root(opts), "_disabled", name, "config.yaml"]))
  end

  @doc """
  Persist a new adapter instance. Validates `name` against the project
  identifier pattern and rejects leading underscore (reserved). Writes
  `adapters/<name>/config.yaml` atomically.

  Returns `{:error, :invalid_name}`, `{:error, :already_exists}`, or
  `:ok`.
  """
  @spec add(instance_name(), String.t(), map(), keyword()) ::
          :ok | {:error, atom() | {atom(), term()}}
  def add(name, type, config, opts \\ [])
      when is_binary(name) and is_binary(type) and is_map(config) do
    cond do
      not valid_name?(name) ->
        {:error, :invalid_name}

      exists?(name, opts) ->
        {:error, :already_exists}

      true ->
        path = Path.join([adapters_root(opts), name, "config.yaml"])
        doc = %{"type" => type, "config" => config}

        case Esr.Yaml.Writer.write_atomic(path, doc) do
          :ok -> :ok
          {:error, reason} -> {:error, {:write_failed, reason}}
        end
    end
  end

  @doc """
  Remove `adapters/<name>` recursively. Returns `{:error, :not_found}`
  if the directory does not exist.
  """
  @spec remove(instance_name(), keyword()) :: :ok | {:error, :not_found}
  def remove(name, opts \\ []) when is_binary(name) do
    dir = Path.join(adapters_root(opts), name)

    cond do
      not File.exists?(dir) ->
        {:error, :not_found}

      true ->
        File.rm_rf!(dir)
        :ok
    end
  end

  @doc """
  Move `adapters/<name>` → `adapters/_disabled/<name>`. The runtime
  ignores disabled rows on next `list/1`. Idempotent: returns
  `{:error, :already_disabled}` if the disabled-side directory already
  exists, `{:error, :not_found}` if neither side has it.
  """
  @spec disable(instance_name(), keyword()) :: :ok | {:error, atom()}
  def disable(name, opts \\ []) when is_binary(name) do
    src = Path.join(adapters_root(opts), name)
    dst = Path.join([adapters_root(opts), "_disabled", name])

    cond do
      not File.exists?(src) and File.exists?(dst) ->
        {:error, :already_disabled}

      not File.exists?(src) ->
        {:error, :not_found}

      File.exists?(dst) ->
        {:error, :already_disabled}

      true ->
        :ok = File.mkdir_p(Path.dirname(dst))

        case File.rename(src, dst) do
          :ok -> :ok
          {:error, reason} -> {:error, {:rename_failed, reason}}
        end
    end
  end

  @doc """
  Move `adapters/_disabled/<name>` → `adapters/<name>`. Inverse of
  `disable/2`. Returns `{:error, :not_disabled}` if the disabled-side
  entry is missing, `{:error, :already_enabled}` if the active-side
  already has it.
  """
  @spec enable(instance_name(), keyword()) :: :ok | {:error, atom()}
  def enable(name, opts \\ []) when is_binary(name) do
    src = Path.join([adapters_root(opts), "_disabled", name])
    dst = Path.join(adapters_root(opts), name)

    cond do
      not File.exists?(src) ->
        {:error, :not_disabled}

      File.exists?(dst) ->
        {:error, :already_enabled}

      true ->
        :ok = File.mkdir_p(Path.dirname(dst))

        case File.rename(src, dst) do
          :ok -> :ok
          {:error, reason} -> {:error, {:rename_failed, reason}}
        end
    end
  end

  @doc """
  Rename `adapters/<old>` → `adapters/<new>`. `new_name` is validated
  the same way as `add/4`. Returns `{:error, :invalid_name}`,
  `{:error, :not_found}`, `{:error, :already_exists}`, or `:ok`.
  """
  @spec rename(instance_name(), instance_name(), keyword()) :: :ok | {:error, atom()}
  def rename(old_name, new_name, opts \\ [])
      when is_binary(old_name) and is_binary(new_name) do
    src = Path.join(adapters_root(opts), old_name)
    dst = Path.join(adapters_root(opts), new_name)

    cond do
      not valid_name?(new_name) ->
        {:error, :invalid_name}

      not File.exists?(src) ->
        {:error, :not_found}

      File.exists?(dst) ->
        {:error, :already_exists}

      true ->
        case File.rename(src, dst) do
          :ok -> :ok
          {:error, reason} -> {:error, {:rename_failed, reason}}
        end
    end
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp adapters_root(opts) do
    case Keyword.get(opts, :home) do
      nil -> Esr.Paths.adapters_dir()
      home -> Path.join(home, "adapters")
    end
  end

  defp list_dir_entries(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.filter(entries, fn name ->
          File.dir?(Path.join(dir, name))
        end)

      {:error, _} ->
        []
    end
  end

  # Returns `[adapter]` or `[]` (so callers can flat_map). An entry with
  # a missing or malformed config.yaml is dropped; this is a list-time
  # tolerance — `get/2` raises by returning `:not_found` for the same.
  defp read_one(root, name) do
    path = Path.join([root, name, "config.yaml"])

    case File.read(path) do
      {:ok, content} ->
        case YamlElixir.read_from_string(content) do
          {:ok, %{"type" => type, "config" => config}}
          when is_binary(type) and is_map(config) ->
            [%{name: name, type: type, config: config}]

          {:ok, %{"type" => type}} when is_binary(type) ->
            [%{name: name, type: type, config: %{}}]

          _ ->
            []
        end

      {:error, _} ->
        []
    end
  end

  defp valid_name?(name) when is_binary(name) do
    not String.starts_with?(name, "_") and Regex.match?(@name_pattern, name)
  end

  defp valid_name?(_), do: false
end
