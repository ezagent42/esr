defmodule Esr.PubSubAuditTest do
  @moduledoc """
  P3-15 audit guard. Enumerates every literal topic passed to
  `Phoenix.PubSub.broadcast` / `EsrWeb.Endpoint.broadcast` in
  `runtime/lib/` and asserts each one matches the post-PR-3 allow-list
  documented in `docs/notes/pubsub-audit-pr3.md`.

  Any new broadcast call-site with a topic outside the allow-list fails
  this test — forcing the author to either (a) justify it in the audit
  doc and add the pattern here, or (b) switch to neighbor-ref send/cast
  per spec §2.9.

  Test is static (reads source files); no runtime dependency.
  """

  use ExUnit.Case, async: true

  @moduletag :audit

  @allowed_patterns [
    ~r/^adapter:/,
    ~r/^handler:/,
    ~r/^handler_reply:/,
    ~r/^directive_ack:/,
    ~r/^cli:channel\//,
    ~r/^cc_mcp_ready\//,
    ~r/^session_router$/,
    ~r/^grants_changed:/,
    # PR-C 2026-04-27 actor-topology-routing §7: workspaces.yaml
    # hot-reload broadcasts `{:topology_neighbour_added, ws, uri}` on
    # `topology:<ws>` (per-workspace) and `topology:events` (global).
    ~r/^topology:/
  ]

  # Dynamic-topic call-sites — the broadcast's first-string arg is a
  # variable, not a literal. We still verify these exist in their
  # expected files so a silent refactor that turns a dynamic topic into
  # a new literal shape can't slip past the allow-list.
  @expected_dynamic_sites [
    "lib/esr/admin/commands/notify.ex",
    "lib/esr/admin/commands/scope/branch_end.ex",
    "lib/esr/handler_router.ex",
    "lib/esr/peer_server.ex",
    "lib/esr_web/handler_channel.ex",
    "lib/esr_web/adapter_channel.ex",
    "lib/esr/peers/feishu_app_adapter.ex",
    "lib/esr/capabilities/grants.ex"
  ]

  @broadcast_call_re ~r/(?:Phoenix\.PubSub\.broadcast|EsrWeb\.Endpoint\.broadcast)/

  # Two wire shapes we scan:
  #
  #   * `Phoenix.PubSub.broadcast(PUBSUB_NAME, "<TOPIC>", MESSAGE)`
  #     — topic is the 2nd argument; a string literal matches here is
  #       the allow-listed topic literal.
  #
  #   * `EsrWeb.Endpoint.broadcast("<TOPIC>", "EVENT", PAYLOAD)`
  #     — topic is the 1st argument. In all current sites this is a
  #       variable (e.g. `topic`, `channel_topic`) or an interpolated
  #       string with a prefix match; we capture the prefix before the
  #       interpolation via the same 1st-arg literal regex below.
  #
  # The 2nd-arg event string ("envelope") on Endpoint.broadcast calls
  # must NOT be matched as a topic — that was the failure-mode a naive
  # "any literal after `broadcast`" regex hits.

  @pubsub_broadcast_re ~r/Phoenix\.PubSub\.broadcast\s*\(\s*[A-Za-z_][\w.]*\s*,\s*"([^"]+)"/
  @endpoint_broadcast_re ~r/EsrWeb\.Endpoint\.broadcast\s*\(\s*"([^"]+)"/

  describe "broadcast topic allow-list" do
    test "every literal broadcast topic in runtime/lib/ matches the allow-list" do
      violations =
        lib_files()
        |> Enum.flat_map(&scan_file/1)
        |> Enum.reject(fn {_file, topic} -> allowed?(topic) end)

      assert violations == [],
             "Unallowed PubSub broadcast topics (add to allow-list in " <>
               "pubsub_audit_test.exs + docs/notes/pubsub-audit-pr3.md, or " <>
               "switch to neighbor-ref send/cast):\n" <>
               Enum.map_join(violations, "\n", fn {f, t} -> "  #{f}: #{t}" end)
    end

    test "dynamic-topic broadcast call-sites still live where P3-15 documented them" do
      # If one of these files loses its broadcast call, the audit doc is
      # stale — flag it. If a *new* file contains a broadcast call, the
      # literal-topic test above will catch the case where the topic is
      # a literal. This second test catches the case where the literal
      # test wouldn't fire (dynamic topic in a newly-introduced site).
      missing =
        @expected_dynamic_sites
        |> Enum.reject(&contains_broadcast?/1)

      assert missing == [],
             "Expected these files to contain a `broadcast` call but " <>
               "they don't — audit doc is stale:\n" <>
               Enum.map_join(missing, "\n", &"  #{&1}")
    end
  end

  defp lib_files do
    Path.wildcard("lib/**/*.ex")
    |> Enum.reject(&String.contains?(&1, "_build/"))
  end

  defp scan_file(path) do
    content = File.read!(path)
    pubsub = Regex.scan(@pubsub_broadcast_re, content, capture: :all_but_first)
    endpoint = Regex.scan(@endpoint_broadcast_re, content, capture: :all_but_first)

    (pubsub ++ endpoint)
    |> Enum.map(fn [topic] -> {path, topic} end)
  end

  defp contains_broadcast?(relpath) do
    full = Path.join(File.cwd!(), relpath)

    if File.exists?(full) do
      full
      |> File.read!()
      |> String.match?(@broadcast_call_re)
    else
      false
    end
  end

  defp allowed?(topic) do
    Enum.any?(@allowed_patterns, &Regex.match?(&1, topic))
  end
end
