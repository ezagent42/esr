defmodule Esr.SessionTemplate.AgentDefBuilder do
  @moduledoc """
  Materializes a parsed `Esr.SessionTemplate` into the `agent_def`-shaped
  map that `Esr.Session.AgentSpawner` consumes.

  This is the seam Phase 5 introduces between the template (declarative
  yaml) and the spawn pipeline (already a generic walker). The walker
  stays unchanged; only the source of the agent_def map changes from
  `Esr.Entity.Agent.Registry.agent_def/1` (agents.yaml) to
  `Esr.SessionTemplate.Registry.materialize/2` (template + runtime_params).

  ## Phase 5 scope: feishu-cc topology

  The single supported topology composes:

  * Channel `<plugin>.feishu.chat_proxy` (alias e.g. `in`) →
    `Esr.Plugins.Feishu.FeishuChatProxy` inbound peer +
    `Esr.Entity.FeishuAppProxy` stateless proxy targeting
    `admin::feishu_app_adapter_${app_id}`.
  * Agent kind `claude_code.cc` →
    `Esr.Entity.CCProxy` + `Esr.Entity.CCProcess` + `Esr.Entity.PtyProcess`
    inbound peers in that order.

  The combined inbound chain matches today's `agents.yaml`
  `cc` agent fixture exactly, so the spawn pipeline produces an
  identical session subtree before/after the cut-over.

  ## Phase 6 generalization (deferred)

  When `agents.yaml` dissolves (Phase 6 plan), each plugin's manifest
  will declare its `agent_kinds:` block with explicit
  `pipeline_contributions` describing which peers a kind brings to the
  inbound chain. Channels will likewise declare their peer
  contributions in the manifest's `channels:` block. This module's
  hard-coded `kind → contributions` table is the explicit Phase 5
  bridge and is intentionally narrow — the structural fix lands in
  Phase 6.

  Spec: `docs/superpowers/specs/2026-05-10-session-template-and-channel.md`
  §5.4. Plan Phase 5 Task 5.2.
  """

  alias Esr.SessionTemplate

  @feishu_chat_proxy_kind "feishu.chat_proxy"
  @claude_code_mcp_http_kind "claude_code.mcp_http"
  @claude_code_cc_kind "claude_code.cc"

  @doc """
  Build an agent_def map from a parsed `SessionTemplate` + runtime params.

  Returns `{:ok, agent_def}` on success or `{:error, reason}`.

  Recognized error reasons:
    * `{:unsupported_channel_kind, kind}` — Phase 5 only knows
      `feishu.chat_proxy` and `claude_code.mcp_http`.
    * `{:unsupported_agent_kind, kind}` — Phase 5 only knows
      `claude_code.cc`.
    * `{:missing_runtime_param, key}` — `<runtime>` substitution
      requested for a key the caller didn't supply.
    * `{:no_agents, template_name}` — template declared no agents.
  """
  @spec build(SessionTemplate.t(), map()) :: {:ok, map()} | {:error, term()}
  def build(%SessionTemplate{} = template, runtime_params)
      when is_map(runtime_params) do
    with :ok <- ensure_supported_channel_kinds(template),
         :ok <- ensure_supported_agent_kinds(template),
         {:ok, agent_entry} <- pick_first_agent(template),
         {:ok, channel_inbound} <- channel_pipeline_contributions(template, runtime_params),
         {:ok, channel_proxies} <- channel_proxy_contributions(template),
         {:ok, agent_inbound} <- agent_pipeline_contributions(agent_entry),
         {:ok, capabilities} <- agent_capabilities(agent_entry) do
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
        params: []
      }

      {:ok, agent_def}
    end
  end

  # ------------------------------------------------------------------
  # Phase 5 narrow validation: refuse unknown kinds rather than silently
  # producing a mis-wired agent_def. Phase 6 lifts this restriction by
  # sourcing kind → contributions from plugin manifests.
  # ------------------------------------------------------------------

  defp ensure_supported_channel_kinds(%SessionTemplate{channels: channels}) do
    case Enum.find(channels, fn %{kind: k} -> k not in supported_channel_kinds() end) do
      nil -> :ok
      %{kind: k} -> {:error, {:unsupported_channel_kind, k}}
    end
  end

  defp ensure_supported_agent_kinds(%SessionTemplate{agents: agents}) do
    case Enum.find(agents, fn %{kind: k} -> k not in supported_agent_kinds() end) do
      nil -> :ok
      %{kind: k} -> {:error, {:unsupported_agent_kind, k}}
    end
  end

  defp supported_channel_kinds, do: [@feishu_chat_proxy_kind, @claude_code_mcp_http_kind]
  defp supported_agent_kinds, do: [@claude_code_cc_kind]

  defp pick_first_agent(%SessionTemplate{agents: [first | _]}), do: {:ok, first}
  defp pick_first_agent(%SessionTemplate{name: name}), do: {:error, {:no_agents, name}}

  # ------------------------------------------------------------------
  # Channel contributions
  # ------------------------------------------------------------------

  # Each `feishu.chat_proxy` channel contributes a FeishuChatProxy inbound
  # peer + a FeishuAppProxy stateless proxy targeting the app_id-stamped
  # admin adapter. Per the existing simple.yaml `cc` fixture (and per the
  # ChatProxy Channel impl moduledoc, which says FCP keeps its full
  # responsibility unchanged in Phase 5), the FCP peer name is fixed at
  # `feishu_chat_proxy`.
  defp channel_pipeline_contributions(%SessionTemplate{channels: channels}, _runtime_params) do
    contributions =
      channels
      |> Enum.flat_map(fn
        %{kind: @feishu_chat_proxy_kind} ->
          [%{"name" => "feishu_chat_proxy", "impl" => "Esr.Plugins.Feishu.FeishuChatProxy"}]

        %{kind: @claude_code_mcp_http_kind} ->
          # The MCP HTTP Channel today doesn't add an inbound peer of
          # its own — CCProcess + PtyProcess (contributed by the cc
          # agent kind) own the MCP plumbing. The Channel.Instances
          # registration exists for SessionTemplate runtime addressing
          # only. Phase 6 may add a dedicated McpHttp peer here.
          []
      end)

    {:ok, contributions}
  end

  defp channel_proxy_contributions(%SessionTemplate{channels: channels}) do
    proxies =
      channels
      |> Enum.flat_map(fn
        %{kind: @feishu_chat_proxy_kind} ->
          [
            %{
              "name" => "feishu_app_proxy",
              "impl" => "Esr.Entity.FeishuAppProxy",
              # The `${app_id}` literal is left intact for downstream
              # `Esr.Session.AgentSpawner.build_ctx/2` to substitute at
              # spawn time (it reads `params[:app_id]`). Treating it
              # here would prematurely freeze the wrong app_id when
              # different sessions reuse the same materialized template.
              "target" => "admin::feishu_app_adapter_${app_id}"
            }
          ]

        %{kind: @claude_code_mcp_http_kind} ->
          []
      end)

    {:ok, proxies}
  end

  # ------------------------------------------------------------------
  # Agent contributions
  # ------------------------------------------------------------------

  # The cc agent kind contributes the canonical CC chain in inbound
  # order: cc_proxy → cc_process → pty_process. Names match the
  # existing simple.yaml fixture so any downstream actor lookup keyed
  # on those names continues to resolve.
  defp agent_pipeline_contributions(%{kind: @claude_code_cc_kind}) do
    {:ok,
     [
       %{"name" => "cc_proxy", "impl" => "Esr.Entity.CCProxy"},
       %{"name" => "cc_process", "impl" => "Esr.Entity.CCProcess"},
       %{"name" => "pty_process", "impl" => "Esr.Entity.PtyProcess"}
     ]}
  end

  # Phase 5 cap requirements mirror today's `cc` agent in
  # runtime/test/esr/fixtures/agents/simple.yaml. Phase 6 will read
  # these from the plugin manifest's `agent_kinds[].capabilities_required`.
  defp agent_capabilities(%{kind: @claude_code_cc_kind}) do
    {:ok,
     [
       "session:default/create",
       "pty:default/spawn",
       "handler:cc_adapter_runner/invoke"
     ]}
  end
end
