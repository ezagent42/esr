defmodule Esr.SessionTemplate.AgentDefBuilder do
  @moduledoc """
  Materializes a parsed `Esr.SessionTemplate` into the `agent_def`-shaped
  map that `Esr.Session.AgentSpawner` consumes.

  This is the seam Phase 5 introduced between the template (declarative
  yaml) and the spawn pipeline (already a generic walker). The walker
  stays unchanged; only the source of the agent_def map changes.

  ## Phase 5 → Phase 6 generalization (2026-05-10)

  Phase 5 hardcoded the kind→contributions mapping for the single
  feishu-cc topology. Phase 6 generalizes:

  * For each `template.channels[]` entry with `kind: <plugin>.<channel>`,
    look up the channel via `Esr.Channel.Registry.lookup_spec/1`. The
    spec's `pipeline_contributions:` list is appended to the inbound
    chain; the spec's `proxies:` list is appended to the agent_def's
    proxies.
  * For each `template.agents[]` entry with `kind: <plugin>.<kind_name>`,
    look up the agent_kind via `Esr.Plugin.AgentKindRegistry.lookup/1`.
    The kind's `pipeline.inbound` is appended to the inbound chain;
    `capabilities_required` becomes the agent_def's
    `capabilities_required`.

  New agent kinds (codex, gemini-cli, voice) just register their
  `agent_kinds:` block in their plugin manifest; no AgentDefBuilder
  code change. New channel kinds same — declare `channels:` with
  optional `pipeline_contributions:` + `proxies:` and they're
  composable into any template.

  Spec: `docs/superpowers/specs/2026-05-10-session-template-and-channel.md`
  §5.4 + §6.
  """

  alias Esr.SessionTemplate

  @doc """
  Build an agent_def map from a parsed `SessionTemplate` + runtime
  params.

  Returns `{:ok, agent_def}` on success or `{:error, reason}`.

  Recognized error reasons:
    * `{:unsupported_channel_kind, kind}` — `kind` not registered in
      `Esr.Channel.Registry` (no enabled plugin manifest declares it).
    * `{:unsupported_agent_kind, kind}` — `kind` not registered in
      `Esr.Plugin.AgentKindRegistry` (no enabled plugin manifest
      declares it).
    * `{:no_agents, template_name}` — template declared no agents.

  `runtime_params` carries `<runtime>` placeholder values
  (chat_id, app_id, principal_id, name) — passthrough today; reserved
  for future per-runtime parameter substitution.
  """
  @spec build(SessionTemplate.t(), map()) :: {:ok, map()} | {:error, term()}
  def build(%SessionTemplate{} = template, runtime_params)
      when is_map(runtime_params) do
    with {:ok, agent_entry} <- pick_first_agent(template),
         {:ok, channel_inbound, channel_proxies} <- channel_contributions(template),
         {:ok, agent_inbound, capabilities, params} <- agent_contributions(agent_entry) do
      inbound = channel_inbound ++ agent_inbound
      outbound = Enum.reverse(Enum.map(inbound, & &1["name"]))

      agent_def = %{
        description: template.description || "",
        capabilities_required: capabilities,
        pipeline: %{
          inbound: inbound,
          outbound: outbound
        },
        proxies: channel_proxies,
        params: params
      }

      {:ok, agent_def}
    end
  end

  defp pick_first_agent(%SessionTemplate{agents: [first | _]}), do: {:ok, first}
  defp pick_first_agent(%SessionTemplate{name: name}), do: {:error, {:no_agents, name}}

  # ------------------------------------------------------------------
  # Channel contributions — sourced from Esr.Channel.Registry's spec
  # map (Phase 6). Each registered channel may declare optional
  # pipeline_contributions: + proxies: lists in its manifest.
  # ------------------------------------------------------------------
  defp channel_contributions(%SessionTemplate{channels: channels}) do
    Enum.reduce_while(channels, {:ok, [], []}, fn %{kind: kind}, {:ok, inbound_acc, proxies_acc} ->
      case Esr.Channel.Registry.lookup_spec(kind) do
        {:ok, %{pipeline_contributions: contribs, proxies: proxies}} ->
          {:cont, {:ok, inbound_acc ++ contribs, proxies_acc ++ proxies}}

        :not_found ->
          {:halt, {:error, {:unsupported_channel_kind, kind}}}
      end
    end)
  end

  # ------------------------------------------------------------------
  # Agent contributions — sourced from Esr.Plugin.AgentKindRegistry's
  # spec map (Phase 6). The kind's `pipeline.inbound` becomes the
  # agent-side of the chain; `capabilities_required` propagates to the
  # agent_def for cap-gate verification at session create time.
  # ------------------------------------------------------------------
  defp agent_contributions(%{kind: kind}) do
    case Esr.Plugin.AgentKindRegistry.lookup(kind) do
      {:ok, %{pipeline: %{inbound: inbound}, capabilities_required: caps, params: params}} ->
        {:ok, inbound, caps, params}

      :not_found ->
        {:error, {:unsupported_agent_kind, kind}}
    end
  end
end
