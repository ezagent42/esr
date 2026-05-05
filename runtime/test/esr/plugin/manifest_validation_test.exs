defmodule Esr.Plugin.ManifestValidationTest do
  @moduledoc """
  Phase F (PR-4.5, 2026-05-05): live-codebase manifest validation.

  Walks every `runtime/lib/esr/plugins/<name>/manifest.yaml` in the
  source tree and asserts:

    1. Every `entities:` entry's `module:` resolves to a loaded
       Elixir module. Catches the class of bug where a plugin
       manifest references `Esr.Entity.GhostPeer` after the module
       was renamed/removed without updating the manifest.

    2. Every `python_sidecars:` entry's `python_module` runner
       package is importable from the `py/` venv. The check is
       structural — we look for the runner under
       `<repo>/handlers/<runner>/` (the canonical layout matching
       what `Esr.Resource.Sidecar.Registry.spec_for/1` resolves at
       boot). A missing directory fails the test.

  This is the Phase 3/4 finish's manifest-truthfulness gate: a manifest
  drift is caught at `mix test` time, not at runtime when a plugin
  starts (and silently no-ops because `safe_concat/1` swallowed the
  error).

  See `docs/notes/2026-05-05-cli-dual-rail.md` for the broader
  "completion claim requires invariant test" discipline.
  """

  use ExUnit.Case, async: true

  @plugins_root Path.expand("../../../lib/esr/plugins", __DIR__)
  @repo_root Path.expand("../../../..", __DIR__)
  @handlers_root Path.join(@repo_root, "handlers")
  @adapters_root Path.join(@repo_root, "adapters")

  test "every entity module declared in plugin manifests is loadable" do
    failures =
      manifests()
      |> Enum.flat_map(fn {plugin, manifest} ->
        manifest
        |> Map.get("declares", %{})
        |> Map.get("entities", [])
        |> List.wrap()
        |> Enum.flat_map(fn entry ->
          module_str = entry["module"] || entry[:module]

          case validate_module(module_str) do
            :ok -> []
            {:error, reason} -> [{plugin, module_str, reason}]
          end
        end)
      end)

    assert failures == [],
           "manifest entity validation failed:\n" <>
             Enum.map_join(failures, "\n", fn {p, m, r} -> "  #{p}: #{m} — #{r}" end)
  end

  test "every python_sidecar runner declared in plugin manifests has a directory" do
    failures =
      manifests()
      |> Enum.flat_map(fn {plugin, manifest} ->
        manifest
        |> Map.get("declares", %{})
        |> Map.get("python_sidecars", [])
        |> List.wrap()
        |> Enum.flat_map(fn entry ->
          runner = entry["python_module"] || entry[:python_module]

          case validate_runner(runner) do
            :ok -> []
            {:error, reason} -> [{plugin, runner, reason}]
          end
        end)
      end)

    assert failures == [],
           "manifest python_sidecar validation failed:\n" <>
             Enum.map_join(failures, "\n", fn {p, r, why} -> "  #{p}: #{r} — #{why}" end)
  end

  # --- helpers --------------------------------------------------------

  defp manifests do
    @plugins_root
    |> File.ls!()
    |> Enum.flat_map(fn name ->
      manifest_path = Path.join([@plugins_root, name, "manifest.yaml"])

      if File.regular?(manifest_path) do
        case YamlElixir.read_from_file(manifest_path) do
          {:ok, %{} = m} -> [{name, m}]
          _ -> [{name, %{}}]
        end
      else
        []
      end
    end)
  end

  defp validate_module(nil), do: {:error, "missing :module field"}
  defp validate_module(""), do: {:error, "empty :module field"}

  defp validate_module(module_str) when is_binary(module_str) do
    mod = Module.concat([module_str])

    if Code.ensure_loaded?(mod) do
      :ok
    else
      {:error, "module not loadable (mistype, renamed, or removed?)"}
    end
  rescue
    ArgumentError -> {:error, "invalid module name"}
  end

  defp validate_runner(nil), do: {:error, "missing python_module field"}
  defp validate_runner(""), do: {:error, "empty python_module field"}

  defp validate_runner(runner) when is_binary(runner) do
    # Canonical layout: handlers/<runner>/ for handler-style sidecars,
    # adapters/<short>/ for adapter-style. The `<short>` is everything
    # before `_adapter_runner` — feishu_adapter_runner → adapters/feishu/.
    handler_dir = Path.join(@handlers_root, runner)

    adapter_short =
      runner
      |> String.replace_suffix("_adapter_runner", "")
      |> String.replace_suffix("_runner", "")

    adapter_dir = Path.join(@adapters_root, adapter_short)

    cond do
      File.dir?(handler_dir) -> :ok
      File.dir?(adapter_dir) -> :ok
      true -> {:error, "no handlers/#{runner}/ or adapters/#{adapter_short}/ directory"}
    end
  end
end
