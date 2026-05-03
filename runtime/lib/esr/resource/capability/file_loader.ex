defmodule Esr.Resource.Capability.FileLoader do
  @moduledoc """
  Parses capabilities.yaml, validates each entry against the
  Permissions.Registry, and atomically swaps the Grants snapshot.

  Load is non-destructive on failure: if validation fails, the existing
  snapshot is retained and the caller sees the specific error.
  """

  @behaviour Esr.Role.Control
  require Logger

  alias Esr.Resource.Capability.Grants
  alias Esr.Resource.Permission.Registry

  @spec load(Path.t()) :: :ok | {:error, term()}
  def load(path) do
    cond do
      not File.exists?(path) ->
        Grants.load_snapshot(%{})
        :ok

      true ->
        with {:ok, yaml} <- parse(path),
             {:ok, snapshot} <- validate(yaml) do
          Grants.load_snapshot(snapshot)
          Logger.info("capabilities: loaded #{map_size(snapshot)} principals from #{path}")
          :ok
        else
          {:error, reason} = err ->
            Logger.error(
              "capabilities: load failed (#{inspect(reason)}); keeping previous snapshot"
            )

            err
        end
    end
  end

  defp parse(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, yaml} -> {:ok, yaml}
      {:error, err} -> {:error, {:yaml_parse, err}}
    end
  end

  defp validate(yaml) when is_map(yaml) do
    principals = Map.get(yaml, "principals", [])

    Enum.reduce_while(principals, {:ok, %{}}, fn entry, {:ok, acc} ->
      case validate_entry(entry) do
        {:ok, pid, held} -> {:cont, {:ok, Map.put(acc, pid, held)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp validate_entry(%{"id" => pid, "capabilities" => caps} = _entry)
       when is_binary(pid) and is_list(caps) do
    Enum.reduce_while(caps, {:ok, pid, []}, fn cap, {:ok, pid, acc} ->
      case validate_cap(cap, pid) do
        :ok -> {:cont, {:ok, pid, [cap | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, pid, held} -> {:ok, pid, Enum.reverse(held)}
      err -> err
    end
  end

  defp validate_entry(entry), do: {:error, {:malformed_entry, entry}}

  defp validate_cap("*", _pid), do: :ok

  defp validate_cap(cap, pid) when is_binary(cap) do
    cond do
      # PR-21s 2026-04-29: flat dotted caps (`workspace.create`,
      # `session.list`, `cap.manage`, `notify.send`, …) are admitted
      # at load time if they appear in the runtime's declared
      # permissions registry. Match logic (Grants.matches?/2) gained an
      # exact-string fallback in the same PR. docs/notes/
      # capability-name-format-mismatch.md is the historical context.
      not String.contains?(cap, "/") ->
        if Registry.declared?(cap) do
          :ok
        else
          {:error, {:unknown_permission, cap, pid}}
        end

      true ->
        with [scope, perm] <- String.split(cap, "/", parts: 2),
             :ok <- validate_scope(scope),
             :ok <- validate_perm_with_full_fallback(perm, cap, pid) do
          :ok
        else
          {:error, _} = err -> err
          _ -> {:error, {:malformed_cap, cap, pid}}
        end
    end
  end

  # PR-21γ 2026-04-30 — `Esr.Admin.permissions/0` declares some scoped
  # caps as full strings (`session:default/create`, `session:default/end`)
  # rather than just the perm part (`create`, `end`). The split-based
  # validate_perm/2 only sees the post-`/` segment, which doesn't match
  # the full registered string. Fall back to checking whether the full
  # cap is registered as a literal — covers the legacy declaration shape
  # without forcing a registry rewrite.
  defp validate_perm_with_full_fallback(perm, full_cap, pid) do
    case validate_perm(perm, pid) do
      :ok -> :ok
      {:error, _} -> if Registry.declared?(full_cap), do: :ok, else: {:error, {:unknown_permission, perm, pid}}
    end
  end

  defp validate_scope("workspace:" <> name = scope) do
    # Spec §11: warn but don't fail if workspace not yet configured.
    # Cross-check against Esr.Resource.Workspace.Registry if it's up.
    cond do
      name == "*" ->
        :ok

      Process.whereis(Esr.Resource.Workspace.Registry) == nil ->
        :ok

      workspace_exists?(name) ->
        :ok

      true ->
        Logger.warning(
          "capabilities: workspace #{inspect(name)} in grant #{scope} is not in workspaces.yaml (keeping entry anyway)"
        )

        :ok
    end
  end

  defp validate_scope("*"), do: :ok

  # PR-21γ 2026-04-30: accept `session:<name>` scope prefix. The runtime's
  # admin command surface (`Esr.Admin.permissions/0`) declares
  # `session:default/create` and `session:default/end` for the agent-
  # session lifecycle (PR-3 P3-8/P3-9). Without this clause, any yaml
  # carrying those caps would fail validation with `:bad_scope_prefix`
  # and the entire `capabilities.yaml` snapshot would be rejected —
  # leaving the runtime with empty grants and every check denying.
  # We don't cross-check session names against any registry (sessions
  # are dynamic, not pre-declared in a yaml file like workspaces).
  defp validate_scope("session:" <> _name), do: :ok

  defp validate_scope(scope), do: {:error, {:bad_scope_prefix, scope}}

  # Esr.Resource.Workspace.Registry exposes get/1 returning {:ok, ws} | :error.
  # No dedicated exists?/1 helper — we use get/1 at the call site.
  defp workspace_exists?(name) do
    case Esr.Resource.Workspace.Registry.get(name) do
      {:ok, _ws} -> true
      :error -> false
    end
  end

  defp validate_perm("*", _pid), do: :ok

  defp validate_perm(perm, pid) do
    if Registry.declared?(perm) do
      :ok
    else
      {:error, {:unknown_permission, perm, pid}}
    end
  end
end
