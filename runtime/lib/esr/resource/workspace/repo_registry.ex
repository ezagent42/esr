defmodule Esr.Resource.Workspace.RepoRegistry do
  @moduledoc """
  Per-instance list of registered repo-bound workspace paths.

  Stored at `$ESRD_HOME/<inst>/registered_repos.yaml`. Each entry is
  the absolute path to a git repo whose `<path>/.esr/workspace.json`
  ESR should load into the workspace registry. Optional `name` is a
  display alias (unused except for human-readable rendering).

  Pure file IO module — no GenServer state. The in-memory registry
  reads from this file at boot and re-reads when CLI commands mutate
  it.
  """

  defmodule Entry do
    @enforce_keys [:path]
    defstruct [:path, :name]
    @type t :: %__MODULE__{path: String.t(), name: String.t() | nil}
  end

  @spec load(String.t()) :: {:ok, [Entry.t()]} | {:error, term()}
  def load(yaml_path) do
    cond do
      not File.exists?(yaml_path) ->
        {:ok, []}

      true ->
        case YamlElixir.read_from_file(yaml_path) do
          {:ok, %{"repos" => repos}} when is_list(repos) ->
            {:ok, Enum.map(repos, &to_entry/1)}

          {:ok, _other} ->
            {:ok, []}

          {:error, reason} ->
            {:error, {:yaml_read_failed, reason}}
        end
    end
  end

  @spec register(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def register(yaml_path, repo_path, opts \\ []) do
    name = Keyword.get(opts, :name)

    {:ok, repos} = load(yaml_path)

    cond do
      Enum.any?(repos, &(&1.path == repo_path)) ->
        :ok

      true ->
        new_repos = repos ++ [%Entry{path: repo_path, name: name}]
        write(yaml_path, new_repos)
    end
  end

  @spec unregister(String.t(), String.t()) :: :ok | {:error, term()}
  def unregister(yaml_path, repo_path) do
    {:ok, repos} = load(yaml_path)
    new_repos = Enum.reject(repos, &(&1.path == repo_path))
    write(yaml_path, new_repos)
  end

  defp to_entry(%{"path" => p} = m), do: %Entry{path: p, name: m["name"]}

  defp write(yaml_path, repos) do
    body = """
    schema_version: 1
    repos:
    #{render_repos(repos)}
    """

    File.mkdir_p!(Path.dirname(yaml_path))
    tmp = yaml_path <> ".tmp"
    :ok = File.write(tmp, body)
    File.rename(tmp, yaml_path)
  end

  defp render_repos([]), do: "  []"

  defp render_repos(repos) do
    repos
    |> Enum.map(fn
      %Entry{name: nil, path: p} -> "  - path: #{p}"
      %Entry{name: n, path: p} -> "  - path: #{p}\n    name: #{n}"
    end)
    |> Enum.join("\n")
  end
end
