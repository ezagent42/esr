defmodule Esr.Plugins.IsolationTest do
  @moduledoc """
  PR-3.4 (2026-05-05): plugin-isolation invariant. Asserts that the
  runtime boot path + per-session state directories do NOT depend on
  feishu-plugin module names by static reference.

  Scope is **intentionally narrow**:

    - `runtime/lib/esr/application.ex` (boot entrypoint)
    - `runtime/lib/esr/scope/` (per-Scope state — admin + per-chat)
    - `runtime/lib/esr/entity/` (per-Entity machinery)
    - `runtime/lib/esr/resource/` (registries / yaml watchers)

  Other directories — `esr_web/` (Phoenix transport),
  `interface/` (contract @moduledoc), `cli/` (escript), `commands/`
  (slash command modules) — are explicitly OUT of scope. The
  architectural goal of PR-3.4 is "the runtime boot path is plugin-
  agnostic" and this test enforces exactly that. Other isolation
  goals (e.g. cli_channel-to-plugin coupling) are separate specs.

  No whitelist, no exception list. If a future PR drags
  `Esr.Plugins.Feishu.*` into one of the four scoped directories,
  that's the architectural regression this test catches — fix the
  reference, don't add an exception.

  Memory rule: `feedback_let_it_crash_no_workarounds` —
  whitelists are a pattern the user explicitly rejected.
  """

  use ExUnit.Case, async: true

  @scoped_paths [
    Path.expand("../../../lib/esr/application.ex", __DIR__),
    Path.expand("../../../lib/esr/scope", __DIR__),
    Path.expand("../../../lib/esr/entity", __DIR__),
    Path.expand("../../../lib/esr/resource", __DIR__)
  ]

  test "no Esr.Plugins.Feishu.* reference in runtime boot path or per-session state dirs" do
    matches =
      @scoped_paths
      |> Enum.flat_map(&list_ex_files/1)
      |> Enum.flat_map(fn file ->
        file
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} ->
          # Skip @moduledoc / @doc / # comments (the test scope is
          # CODE references, not prose). Direct grep would match
          # documentation strings legitimately mentioning feishu.
          # Pattern below catches `Esr.Plugins.Feishu.<X>` in code
          # only — moduledoc heredocs use the `"""` fence which we
          # detect heuristically via "trim starts with #" or by being
          # inside a `@moduledoc """ ... """` block. We adopt the
          # simpler rule: a line is a "code line" if it doesn't start
          # with whitespace+# and isn't entirely inside a string.
          not comment_line?(line) and
            String.contains?(line, "Esr.Plugins.Feishu.")
        end)
        |> Enum.map(fn {line, lineno} -> {file, lineno, String.trim(line)} end)
      end)

    assert matches == [],
           "runtime boot path references plugin module Esr.Plugins.Feishu.* — " <>
             "structural regression. Fix the reference, do not whitelist:\n" <>
             Enum.map_join(matches, "\n", fn {f, ln, l} ->
               "  #{Path.relative_to_cwd(f)}:#{ln}: #{l}"
             end)
  end

  test "no Esr.Scope.Admin.bootstrap_feishu_app_adapters call site exists anywhere" do
    # The function is deleted in PR-3.4. Any reference is a stale
    # caller that needs to be updated to the feishu plugin's startup
    # hook. Scope is intentionally wider for this test (whole
    # runtime/lib + runtime/test) — the function name is unique
    # enough that no false positive is possible.
    repo_lib = Path.expand("../../../lib", __DIR__)
    repo_test = Path.expand("../..", __DIR__)
    self_path = __ENV__.file

    matches =
      [repo_lib, repo_test]
      |> Enum.flat_map(&list_ex_files/1)
      |> Enum.reject(&(&1 == self_path))
      |> Enum.flat_map(fn file ->
        file
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} ->
          not comment_line?(line) and
            String.contains?(line, "Esr.Scope.Admin.bootstrap_feishu_app_adapters")
        end)
        |> Enum.map(fn {line, lineno} -> {file, lineno, String.trim(line)} end)
      end)

    assert matches == [],
           "stale references to deleted Esr.Scope.Admin.bootstrap_feishu_app_adapters:\n" <>
             Enum.map_join(matches, "\n", fn {f, ln, l} ->
               "  #{Path.relative_to_cwd(f)}:#{ln}: #{l}"
             end)
  end

  defp list_ex_files(path) do
    cond do
      File.regular?(path) and String.ends_with?(path, ".ex") ->
        [path]

      File.dir?(path) ->
        path
        |> Path.join("**/*.{ex,exs}")
        |> Path.wildcard()

      true ->
        []
    end
  end

  defp comment_line?(line) do
    trimmed = String.trim_leading(line)
    String.starts_with?(trimmed, "#")
  end
end
