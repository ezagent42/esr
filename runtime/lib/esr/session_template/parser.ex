defmodule Esr.SessionTemplate.Parser do
  @moduledoc """
  Parse + validate a `template.yaml` per spec §5.3.

  Two callers:

    * `Esr.Bundle.Loader` (in-tree bundles + `/plugin:install`'d bundles)
      passes the parsed bundle manifest's `dependencies` so the parser
      doesn't need to read it from the template body.
    * `Esr.Bundle.Loader` for operator-shipped ad-hoc templates (a single
      yaml conflating manifest + template per spec §5.3 "Operator ad-hoc
      templates"); the parser reads `dependencies` from the yaml directly.

  ## Validation rules (spec §5.3 last paragraph)

  At parse time:

    * `schema_version` must be `1`.
    * Every `channels[].kind` is well-formed `<plugin>.<channel_name>`.
      The Parser optionally checks `Esr.Channel.Registry.lookup/1`
      when called with `verify_channels: true`; the Loader uses this
      after plugin load so the registry is populated. Without
      `verify_channels`, only the well-formedness check runs.
    * Every `agents[].kind` is well-formed `<plugin>.<agent_kind>`.
      Phase 4 does NOT verify against an agent_kinds registry — that's
      Phase 6's job.
    * Every `consumes[]` ref must match a `channels[].alias` declared
      in the same template.
    * Every `flow.inbound[].source` references a `channels[].alias`
      plus a `.<event_name>` suffix (e.g. `in.text`).
    * Every `flow.outbound[].sink` references a `channels[].alias`
      plus a `.<action>` suffix (e.g. `in.send`).
    * Every `flow.inbound[].pipeline[]` entry resolves via
      `Esr.SessionTemplate.FlowNodeRegistry.lookup/1`. Special-case:
      built-in router tokens (`<...>`) and module-name strings are both
      registered there. Phase 4 only checks resolvability if
      `verify_flow_nodes: true` is passed; otherwise the entry is
      retained as `{:unresolved, name}` for the Loader to defer.
    * Reject duplicate `channels[].alias` within one template.

  ## Inputs

      Parser.parse(yaml_string, opts \\\\ [])

      opts:
        :dependencies         — map (forced); when provided, supersedes
                                any `dependencies:` block in the yaml.
                                Used by Bundle.Loader after parsing
                                manifest.yaml.
        :verify_channels      — boolean (default false). When true, every
                                `kind` is checked via Channel.Registry.lookup/1.
        :verify_flow_nodes    — boolean (default false). When true, every
                                pipeline entry is checked via
                                FlowNodeRegistry.lookup/1.

  Spec: `docs/superpowers/specs/2026-05-10-session-template-and-channel.md`
  §5.3. Phase 4 (Task 4.2).
  """

  alias Esr.SessionTemplate

  @supported_schema_version 1

  @doc """
  Parse `yaml_string` and return `{:ok, %Esr.SessionTemplate{}}` or
  `{:error, reason}`.
  """
  @spec parse(String.t(), keyword()) :: {:ok, SessionTemplate.t()} | {:error, term()}
  def parse(yaml_string, opts \\ []) when is_binary(yaml_string) do
    with {:ok, parsed} <- read_yaml(yaml_string),
         {:ok, template} <- parse_raw(parsed, opts) do
      {:ok, template}
    end
  end

  defp read_yaml(content) do
    case YamlElixir.read_from_string(content) do
      {:ok, parsed} when is_map(parsed) -> {:ok, parsed}
      {:ok, _other} -> {:error, :not_a_map}
      {:error, reason} -> {:error, {:parse_failed, reason}}
    end
  end

  defp parse_raw(parsed, opts) do
    with {:ok, schema_version} <- fetch_schema_version(parsed),
         name <- parsed["name"],
         description <- parsed["description"] || "",
         {:ok, dependencies} <- resolve_dependencies(parsed, opts),
         {:ok, channels} <- parse_channels(parsed["channels"] || []),
         :ok <- check_unique_aliases(channels),
         {:ok, agents} <- parse_agents(parsed["agents"] || [], channels),
         {:ok, flow} <- parse_flow(parsed["flow"] || %{}, channels, opts),
         :ok <- maybe_verify_channels(channels, opts) do
      {:ok,
       %SessionTemplate{
         schema_version: schema_version,
         name: name,
         description: description,
         dependencies: dependencies,
         channels: channels,
         agents: agents,
         flow: flow
       }}
    end
  end

  defp fetch_schema_version(parsed) do
    case Map.fetch(parsed, "schema_version") do
      {:ok, v} when v == @supported_schema_version ->
        {:ok, v}

      {:ok, other} ->
        {:error, {:schema_version_mismatch, expected: @supported_schema_version, got: other}}

      :error ->
        {:error, {:missing_field, "schema_version"}}
    end
  end

  # If opts carries :dependencies, use it (bundle-shipped path). Otherwise
  # try to read from the yaml body (operator ad-hoc path). Missing → empty.
  defp resolve_dependencies(parsed, opts) do
    case Keyword.fetch(opts, :dependencies) do
      {:ok, deps} when is_map(deps) ->
        {:ok, normalize_dependencies(deps)}

      :error ->
        case parsed["dependencies"] do
          nil -> {:ok, %{plugins: [], bundles: []}}
          %{} = block -> parse_dependencies(block)
          other -> {:error, {:invalid_dependencies, other}}
        end
    end
  end

  defp normalize_dependencies(%{plugins: _} = deps) do
    %{
      plugins: Map.get(deps, :plugins, []),
      bundles: Map.get(deps, :bundles, [])
    }
  end

  defp normalize_dependencies(deps) when is_map(deps) do
    %{
      plugins: Map.get(deps, "plugins") || Map.get(deps, :plugins) || [],
      bundles: Map.get(deps, "bundles") || Map.get(deps, :bundles) || []
    }
  end

  defp parse_dependencies(block) do
    plugins = block["plugins"] || []
    bundles = block["bundles"] || []

    cond do
      not is_list(plugins) ->
        {:error, {:invalid_dependency_list, "plugins", plugins}}

      not is_list(bundles) ->
        {:error, {:invalid_dependency_list, "bundles", bundles}}

      Enum.any?(plugins, &(not (is_binary(&1) and &1 != ""))) ->
        {:error, {:invalid_dependency_entry, "plugins"}}

      Enum.any?(bundles, &(not (is_binary(&1) and &1 != ""))) ->
        {:error, {:invalid_dependency_entry, "bundles"}}

      true ->
        {:ok, %{plugins: plugins, bundles: bundles}}
    end
  end

  # ---- channels ----

  defp parse_channels(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
      case parse_channel_entry(entry) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      err -> err
    end
  end

  defp parse_channels(other), do: {:error, {:channels_not_a_list, other}}

  defp parse_channel_entry(%{} = entry) do
    alias_str = entry["alias"] || entry[:alias]
    kind = entry["kind"] || entry[:kind]
    config = entry["config"] || entry[:config] || %{}

    cond do
      not is_binary(alias_str) or alias_str == "" ->
        {:error, {:channel_missing_field, "alias"}}

      not is_binary(kind) or kind == "" ->
        {:error, {:channel_missing_field, "kind"}}

      not well_formed_kind?(kind) ->
        {:error, {:channel_kind_malformed, kind}}

      not is_map(config) ->
        {:error, {:channel_config_not_a_map, alias_str}}

      true ->
        {:ok, %{alias: alias_str, kind: kind, config: config}}
    end
  end

  defp parse_channel_entry(other), do: {:error, {:channel_not_a_map, other}}

  # `<plugin>.<channel_name>`; both segments lowercase letters / digits / `_` / `-`,
  # at least one char each. Mirror Esr.Plugin.Manifest's kebab tolerance.
  @kind_regex ~r/^[a-z][a-z0-9_-]*\.[a-z][a-z0-9_-]*$/

  defp well_formed_kind?(kind) when is_binary(kind), do: Regex.match?(@kind_regex, kind)

  defp check_unique_aliases(channels) do
    aliases = Enum.map(channels, & &1.alias)

    duplicates =
      aliases
      |> Enum.frequencies()
      |> Enum.filter(fn {_a, n} -> n > 1 end)
      |> Enum.map(fn {a, _} -> a end)

    case duplicates do
      [] -> :ok
      [dup | _] -> {:error, {:duplicate_channel_alias, dup}}
    end
  end

  defp maybe_verify_channels(channels, opts) do
    if Keyword.get(opts, :verify_channels, false) do
      Enum.reduce_while(channels, :ok, fn %{kind: kind, alias: a}, :ok ->
        case Esr.Channel.Registry.lookup(kind) do
          {:ok, _mod} -> {:cont, :ok}
          :not_found -> {:halt, {:error, {:unknown_channel_kind, kind, alias: a}}}
        end
      end)
    else
      :ok
    end
  end

  # ---- agents ----

  defp parse_agents(list, channels) when is_list(list) do
    aliases = MapSet.new(Enum.map(channels, & &1.alias))

    Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
      case parse_agent_entry(entry, aliases) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      err -> err
    end
  end

  defp parse_agents(other, _), do: {:error, {:agents_not_a_list, other}}

  defp parse_agent_entry(%{} = entry, aliases) do
    kind = entry["kind"] || entry[:kind]
    name = entry["name"] || entry[:name]
    consumes = entry["consumes"] || entry[:consumes] || []

    cond do
      not is_binary(kind) or kind == "" ->
        {:error, {:agent_missing_field, "kind"}}

      not well_formed_kind?(kind) ->
        {:error, {:agent_kind_malformed, kind}}

      not is_binary(name) or name == "" ->
        {:error, {:agent_missing_field, "name"}}

      not is_list(consumes) ->
        {:error, {:agent_consumes_not_a_list, consumes}}

      true ->
        case validate_consumes(consumes, aliases) do
          :ok -> {:ok, %{kind: kind, name: name, consumes: consumes}}
          err -> err
        end
    end
  end

  defp parse_agent_entry(other, _), do: {:error, {:agent_not_a_map, other}}

  defp validate_consumes(consumes, aliases) do
    Enum.reduce_while(consumes, :ok, fn entry, :ok ->
      cond do
        not is_binary(entry) or entry == "" ->
          {:halt, {:error, {:consumes_entry_invalid, entry}}}

        not MapSet.member?(aliases, entry) ->
          {:halt, {:error, {:consumes_unknown_alias, entry}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  # ---- flow ----

  defp parse_flow(%{} = flow, channels, opts) do
    inbound_raw = flow["inbound"] || []
    outbound_raw = flow["outbound"] || []
    aliases = MapSet.new(Enum.map(channels, & &1.alias))

    with {:ok, inbound} <- parse_inbound(inbound_raw, aliases, opts),
         {:ok, outbound} <- parse_outbound(outbound_raw, aliases) do
      {:ok, %{inbound: inbound, outbound: outbound}}
    end
  end

  defp parse_flow(other, _, _), do: {:error, {:flow_not_a_map, other}}

  defp parse_inbound(list, aliases, opts) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
      case parse_inbound_entry(entry, aliases, opts) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      err -> err
    end
  end

  defp parse_inbound(other, _, _), do: {:error, {:flow_inbound_not_a_list, other}}

  defp parse_inbound_entry(%{} = entry, aliases, opts) do
    source = entry["source"] || entry[:source]
    pipeline_raw = entry["pipeline"] || entry[:pipeline] || []

    cond do
      not is_binary(source) or source == "" ->
        {:error, {:inbound_missing_field, "source"}}

      not source_alias_known?(source, aliases) ->
        {:error, {:inbound_source_unknown_alias, source}}

      not is_list(pipeline_raw) ->
        {:error, {:inbound_pipeline_not_a_list, pipeline_raw}}

      true ->
        case parse_pipeline(pipeline_raw, opts) do
          {:ok, pipeline} -> {:ok, %{source: source, pipeline: pipeline}}
          err -> err
        end
    end
  end

  defp parse_inbound_entry(other, _, _), do: {:error, {:inbound_entry_not_a_map, other}}

  # source = `<alias>.<event_name>`. Strip suffix and check alias.
  defp source_alias_known?(source, aliases) do
    case String.split(source, ".", parts: 2) do
      [alias_, event] when event != "" -> MapSet.member?(aliases, alias_)
      _ -> false
    end
  end

  defp parse_pipeline(list, opts) when is_list(list) do
    verify = Keyword.get(opts, :verify_flow_nodes, false)

    Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
      case parse_pipeline_entry(entry, verify) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      err -> err
    end
  end

  defp parse_pipeline_entry(name, verify) when is_binary(name) and name != "" do
    cond do
      String.starts_with?(name, "<") and String.ends_with?(name, ">") ->
        # Built-in router token. Verify if requested.
        if verify do
          case Esr.SessionTemplate.FlowNodeRegistry.lookup(name) do
            {:ok, value} -> {:ok, {:builtin, value}}
            :not_found -> {:error, {:unknown_flow_node, name}}
          end
        else
          {:ok, {:unresolved, name}}
        end

      module_name?(name) ->
        # Module reference. We don't require it loaded at parse time
        # (Phase 5/6 may resolve later), but well-formed module
        # identifier is checked.
        if verify do
          case Esr.SessionTemplate.FlowNodeRegistry.lookup(name) do
            {:ok, value} -> {:ok, {:module, ensure_module_atom(value)}}
            :not_found -> {:error, {:unknown_flow_node, name}}
          end
        else
          {:ok, {:unresolved, name}}
        end

      true ->
        {:error, {:invalid_pipeline_entry, name}}
    end
  end

  defp parse_pipeline_entry(other, _), do: {:error, {:invalid_pipeline_entry, other}}

  # Well-formed Elixir module identifier: starts with uppercase,
  # alphanumeric + dots. Doesn't require Code.ensure_loaded?/1 (Phase 5+
  # job). Must contain at least one char and start with capital letter.
  @module_regex ~r/^[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*$/

  defp module_name?(name) when is_binary(name), do: Regex.match?(@module_regex, name)

  defp ensure_module_atom(value) when is_atom(value), do: value
  defp ensure_module_atom(value), do: value

  defp parse_outbound(list, aliases) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
      case parse_outbound_entry(entry, aliases) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      err -> err
    end
  end

  defp parse_outbound(other, _), do: {:error, {:flow_outbound_not_a_list, other}}

  defp parse_outbound_entry(%{} = entry, aliases) do
    source = entry["source"] || entry[:source]
    sink = entry["sink"] || entry[:sink]

    cond do
      not is_binary(source) or source == "" ->
        {:error, {:outbound_missing_field, "source"}}

      not is_binary(sink) or sink == "" ->
        {:error, {:outbound_missing_field, "sink"}}

      not sink_alias_known?(sink, aliases) ->
        {:error, {:outbound_sink_unknown_alias, sink}}

      true ->
        {:ok, %{source: source, sink: sink}}
    end
  end

  defp parse_outbound_entry(other, _), do: {:error, {:outbound_entry_not_a_map, other}}

  # source uses the `<agent>.<event>` template-language token; it's
  # a placeholder resolved at session creation, not against the
  # channels list. The well-formed shape check is "at least one dot,
  # both halves nonempty". Keeps the parser tolerant of templates that
  # haven't enumerated their agents yet (the spec uses `<agent>.reply`
  # as the literal placeholder).
  defp sink_alias_known?(sink, aliases) do
    case String.split(sink, ".", parts: 2) do
      [alias_, action] when action != "" -> MapSet.member?(aliases, alias_)
      _ -> false
    end
  end
end
