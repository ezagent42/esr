# Business-topology MCP tool — design spec

**Date**: 2026-04-28
**Status**: design (post-grill, pre-implementation)
**Author**: dev (linyilun) — captured via `/grill-me` discussion
**Builds on**: PR-E (#61) actor-topology-routing addressability landed
**Targets**: PR-F (`mcp__esr-channel__describe_topology` tool)

---

## 1. Why now

PR-C/D shipped 1-hop **addressability** (`<channel reachable=...>`) — the LLM
knows *who it can send to*. PR-E pinned the wire with scenario 05.

What remains uncovered: **business topology awareness** — the LLM knowing
*its role in a multi-stage pipeline*. Concrete user-facing example
(linyilun, 2026-04-27 grill):

> 实际上，prompt 中我们往往会加入："不用润色文字，主要完成叙事逻辑，
> 之后再润色"这样的说明，实际上就是一种业务拓扑

Without context like this, a `translator` agent might do polish-y work
because it doesn't know `polisher` is a downstream stage. The LLM
needs visibility into the broader pipeline shape so it stays in lane.

## 2. Design discovery

The grill walked through structured-tag-fields proposals before
linyilun pushed back with a simpler alternative:

> 我们会不会把这个问题复杂化了？会不会增加一个 skill 让 LLM 可以
> 解析 yaml 就可以了？

This reframed the problem: business topology is **documentation**, not
**protocol**. yaml encodes it; the LLM reads it on demand. No
runtime-side schema computation needed.

The MCP tool form (option β in the grill) was chosen over:

- **Tag-attribute extension** (δ): inflexible, runtime computes
  speculative fields the LLM may not need this turn.
- **Auto-injection into system prompt** (γ): bloats every prompt
  whether business context is needed or not.
- **Pure skill / Read tool** (α): too passive — LLM may forget the
  yaml exists.

## 3. The tool

### 3.1 Shape

```
mcp__esr-channel__describe_topology()  # no params in v1
  → returns JSON
```

Returns a structured view of the current session's workspace and its
direct (1-hop) neighbours.

### 3.2 Response

```json
{
  "current_workspace": {
    "name": "ws_translator",
    "role": "dev",
    "chats": [
      {"chat_id": "oc_t1", "app_id": "feishu_app_dev",
       "kind": "group", "name": "translator-room"}
    ],
    "neighbors_declared": ["workspace:ws_processor"],
    "metadata": {
      "purpose": "Translate Chinese to English",
      "pipeline_position": 1,
      "hand_off_to": "ws_processor",
      "output_format": "plain text"
    }
  },
  "neighbor_workspaces": [
    {
      "name": "ws_processor",
      "role": "dev",
      "chats": [...],
      "neighbors_declared": [...],
      "metadata": {
        "purpose": "Structure translated text into XYZ format",
        "pipeline_position": 2
      }
    }
  ]
}
```

### 3.3 Field allowlist policy (Lane A/B audit-table lesson)

**Top-level workspace fields exposed**: `name`, `role`, `chats`,
`neighbors_declared`, `metadata`.

**Top-level workspace fields hidden**: `cwd`, `start_cmd`, `env`
(operational config; may contain secrets).

**Per-chat fields exposed**: `chat_id`, `app_id`, `kind`, `name`,
`metadata`.

**`metadata:` is a free-form sub-tree** owned by operators for
business-topology context. Contents flow yaml → tool → LLM verbatim.
No code change required when operators add new business fields.

This is **allowlist-by-default** (per Lane A/B RCA item 4 — be
conservative; leak is the off-diagonal bug). New top-level fields
need an explicit code change before the tool exposes them.

### 3.4 No cap

Per linyilun's principle:

> python 侧 / LLM 侧理论上不应该关心权限问题

The tool does not enforce capability checks. Reasoning (Lane A/B
checklist):

| Lane A/B item | (no cap) result |
|---|---|
| Sunset condition | N/A — no new gate to sunset |
| Quantified win | N/A — yaml is non-secret operator-readable |
| Synced state observable | N/A — single source (yaml on disk) |
| Truth-table audit | 1×1 — Lane B inbound gate already gates session entry |
| Sunset triggers | N/A |
| Duplicate-gate check | not duplicate — single Lane B enforcement |

If yaml ever gains genuinely sensitive fields (paths to home dirs,
API keys, credentials), revisit. Today the allowlist excludes the
fields that would carry secrets.

## 4. Source of truth + IPC path

```
operator writes ${ESRD_HOME}/<instance>/workspaces.yaml
  ↓ fs_watch (PR-C C6)
Esr.Workspaces.Registry (Elixir, ETS)
  ↓ Phoenix channel cli:workspaces/describe (new)
short-lived ChannelClient inside cc_mcp tool handler (new)
  ↓ JSON-RPC tool result
Claude (LLM, prompt context)
```

### 4.1 IPC client — short-lived per call

⚠️ **cc_mcp's existing `EsrWSClient` (`adapters/cc_mcp/src/esr_cc_mcp/ws_client.py`)
opens exactly one topic per session — `cli:channel/<sid>` — and is
not designed for one-shot RPC calls.** It exposes `connect_and_run`
+ `push` (envelope flavoured), no `cli_call` helper.

The pattern PR-F follows is the one already in
`py/src/esr/cli/runtime_bridge.py:45-77` (`call_runtime`):

1. Open a fresh `Phoenix v2` socket
2. Join `cli:workspaces/describe`
3. `phx_call` with the workspace name as the arg
4. Await `phx_reply`
5. Close

PR-F implements this directly in cc_mcp's tool handler (no
cross-package import of `esr.cli`) — a small inline helper inside
`adapters/cc_mcp/src/esr_cc_mcp/tools.py` modeled on `call_runtime`.
cc_mcp stays standalone; future tools that need similar one-shot RPC
can extract the helper if it grows.

Reasons cc_mcp does NOT read yaml directly from disk:

1. **Hot-reload visibility**: runtime's Workspaces.Registry sees the
   freshest topology after the watcher reloads; reading from disk
   would race the watcher.
2. **Single yaml-parser path**: Elixir's YamlElixir is the
   authoritative parse; Python's PyYAML might disagree on edge cases.
3. **Symmetric with other CLI tools**: `esr actors list`,
   `esr cap list`, etc. all go through Phoenix channels — the new
   tool fits the pattern.

### 4.2 Response wrapping convention

Existing `cli:*` dispatch clauses in
`runtime/lib/esr_web/cli_channel.ex` always wrap the return as
`%{"data" => ...}`. PR-F follows the convention:

```elixir
def dispatch("cli:workspaces/describe", %{"arg" => workspace_name}) do
  ...
  %{"data" => %{
    "current_workspace" => filter_workspace(ws),
    "neighbor_workspaces" => Enum.map(neighbours, &filter_workspace/1)
  }}
end
```

The tool handler unwraps `data` before returning to the LLM (so the
LLM sees the §3.2 shape, not the wrapper).

### 4.3 Resolving neighbour workspaces

⚠️ **`Esr.Topology.neighbour_set/1` returns a flattened MapSet of
URIs across all neighbour types (chat, user, adapter, agent), NOT a
list of workspace names.** PR-F's dispatch must instead read
`Workspace.neighbors` directly (the raw `["workspace:<name>", ...]`
list as declared in yaml), parse `workspace:<name>` entries, and
look up each name via `Workspaces.Registry.get/1`.

This is intentional — `neighbour_set/1` is for the BGP-style
reachable-set seeding (PR-C C2); PR-F's view of "neighbour workspaces
the LLM should see metadata for" is a different abstraction (only
workspace-typed entries get expanded into the `neighbor_workspaces`
array; chat/user/adapter neighbours appear in the `current_workspace`'s
`neighbors_declared` field as raw strings for the LLM to interpret).

`workspace_name` is read from `ESR_WORKSPACE` env var (already
present in `cc_mcp/channel.py`). v1 has no override parameter.

## 5. yaml schema extension

`Esr.Workspaces.Registry.Workspace` struct gains `metadata: map()`:

```elixir
defmodule Workspace do
  defstruct [
    :name, :cwd, :start_cmd, :role, :chats, :env,
    neighbors: [],
    metadata: %{}    # NEW: free-form business-topology context
  ]
end
```

`load_from_file/1` parser reads `row["metadata"] || %{}`.

Per-chat `metadata` is part of the chat map (no separate struct
required); the filter just `Map.take(chat, [..., "metadata"])`.

⚠️ **`cli:workspace/register` consistency**: `cli_channel.ex` has a
`dispatch("cli:workspace/register", ...)` clause that builds a
`%Workspace{}` struct from the call payload. PR-F must extend it to
include `metadata: payload["metadata"] || %{}` so registering via
CLI doesn't silently drop the field. (Same as how the original
`neighbors` defaults to `[]` if unset.) Without this, an operator
running `esr workspace register` could lose `metadata:` on round-trip.

## 6. When the LLM should call this tool

Tool description (the LLM's contract):

```
Returns metadata about the current session's workspace and its
direct neighbours. Call this when:

- The user mentions another workspace/team you don't recognize
- You need to understand pipeline context (your role, downstream
  stages, output expectations)
- You're unsure which workspace's chat to route to

Returns: JSON with `current_workspace` (you are here) and
`neighbor_workspaces` (1-hop reachable). Operational fields
(cwd, env, start_cmd) are filtered out.
```

The "when" clauses are deliberately concrete to nudge the LLM toward
calling it during pipeline-shape decisions.

## 7. What is NOT in this PR

- **scenario 06 e2e test**. LLM behavioural validation that claude
  actually calls the tool + uses the response is non-deterministic
  (same flake risk as PR-E scenario 05 design A — see
  `docs/notes/actor-topology-routing.md` "known limitations"). v1
  ships unit-test coverage of the wire (Elixir + Python sides);
  manual smoke covers behaviour.
- **Cross-workspace queries**. v1 always returns the current session's
  workspace + 1-hop neighbours. Future need (cross-team coordination
  agents) can add an optional `workspace=` parameter.
- **Tool-call audit log**. INFO-log on each invocation but no
  structured audit pipeline. If misuse becomes a concern later, add a
  telemetry event.
- **`metadata:` schema enforcement**. Free-form by design — operators
  pick fields suiting their pipelines. No JSON-schema validation
  today.

## 8. Implementation plan

| # | Task | Module(s) |
|---|---|---|
| F1 | This spec doc | `docs/superpowers/specs/2026-04-28-...` |
| F2 | `Workspace.metadata` field + yaml parser + tests | `runtime/lib/esr/workspaces/registry.ex` + tests |
| F3 | `cli:workspaces/describe` endpoint + tests | `runtime/lib/esr_web/cli_channel.ex` + tests |
| F4 | `describe_topology` Python tool + tests | `adapters/cc_mcp/src/esr_cc_mcp/tools.py`, `channel.py` + tests |
| F5 | Example yaml + ops note metadata usage | `docs/notes/actor-topology-routing.md` |

Estimated ~2 hours total.

## 9. References

- Grill transcript: 2026-04-27 (DM `oc_d9b47511...`) Q1–Q8
- PR-E (addressability foundation): #61
- Actor-topology-routing spec: `docs/superpowers/specs/2026-04-27-actor-topology-routing.md`
- Lane A/B RCA (cap policy reasoning): `docs/notes/lane-a-rca.md`
- Operator note: `docs/notes/actor-topology-routing.md` (extended in F5)
