defmodule Mix.Tasks.Esr.CheckUriDrift do
  @moduledoc """
  CI gate: ban old identity-lookup API uses outside designated URI handler files.

  Allowed file paths (path-pattern; NEW files can't be added to a
  "whitelist" ad-hoc):

    runtime/lib/esr/uri.ex
    runtime/lib/esr/uri/**/*.ex
    runtime/lib/esr/plugins/<plugin>/uri_handler.ex

  Banned patterns: legacy `User.Registry` / `User.NameIndex` /
  `Workspace.Registry` / `Workspace.NameIndex` / `Session.NameIndex` /
  `InstanceRegistry` lookup calls.

  Spec §10 (L1' path-pattern gate).
  Plan: docs/superpowers/plans/2026-05-12-uri-identity-plan.md PR-0 Task 0.6.

  ## Behaviour

    * count > baseline → FAIL (net-new drift introduced)
    * count == baseline → PASS (no change)
    * count <  baseline → PASS, but the task suggests ratcheting the
      baseline down

  The baseline lives at `runtime/priv/uri-drift-baseline.txt`. Each
  successful migration PR (PR-1/PR-2/PR-3/PR-4) ratchets it down.
  """

  use Mix.Task

  @shortdoc "Check for old-API uses outside allowed URI handler files"

  @banned_pattern ~r/(?:lookup_by_feishu_id|UserRegistry\.get_default_workspace|UserRegistry\.get_by_id|UserRegistry\.get_by_username|NameIndex\.id_for_name|workspace_for_chat|InstanceRegistry\.primary)/

  # Files allowed to use the old APIs (URI handlers + core URI module).
  # Matched against repo-relative paths beginning with `runtime/lib/...`.
  @allowed_path_re ~r{runtime/lib/esr/uri/.*\.ex$|runtime/lib/esr/plugins/[^/]+/uri_handler\.ex$|runtime/lib/esr/uri\.ex$}

  @baseline_path "priv/uri-drift-baseline.txt"

  @impl Mix.Task
  def run(_args) do
    violations = scan()
    baseline = read_baseline()
    count = length(violations)

    cond do
      count > baseline ->
        Mix.shell().error("uri-drift CI gate: count #{count} > baseline #{baseline}")
        Mix.shell().error("Old identity-API uses found outside allowed handler files:")

        Enum.each(violations, fn {file, line, text} ->
          Mix.shell().error("  #{file}:#{line}: #{String.trim(text)}")
        end)

        Mix.shell().error("")

        Mix.shell().error(
          "Migrate to Esr.Uri.resolve/1 + Esr.Uri.get_entity/1, or place the"
        )

        Mix.shell().error(
          "file under runtime/lib/esr/uri/** or rename it to a plugin's uri_handler.ex."
        )

        exit({:shutdown, 1})

      count < baseline ->
        Mix.shell().info("uri-drift: count #{count} < baseline #{baseline}.")

        Mix.shell().info(
          "Baseline can be ratcheted DOWN — update #{@baseline_path} to #{count} and commit."
        )

        :ok

      true ->
        Mix.shell().info("uri-drift: clean (#{count} matches baseline)")
        :ok
    end
  end

  defp scan do
    # Glob is relative to cwd (typically `runtime/`); rebuild the
    # repo-relative form before matching against @allowed_path_re so
    # the allow-list expressed in `runtime/lib/...` terms is honoured
    # regardless of where mix was invoked.
    "lib/esr/**/*.ex"
    |> Path.wildcard()
    |> Enum.reject(fn path ->
      repo_relative =
        if String.starts_with?(path, "runtime/"), do: path, else: "runtime/" <> path

      Regex.match?(@allowed_path_re, repo_relative)
    end)
    |> Enum.flat_map(fn file ->
      file
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _} -> Regex.match?(@banned_pattern, line) end)
      |> Enum.map(fn {text, idx} -> {file, idx, text} end)
    end)
  end

  defp read_baseline do
    case File.read(@baseline_path) do
      {:ok, content} ->
        content |> String.trim() |> String.to_integer()

      {:error, :enoent} ->
        # No baseline file = treat as 0 (everything is net-new drift).
        0
    end
  end
end
