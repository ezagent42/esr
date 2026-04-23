# PR-7 End-to-End Feishu ↔ CC Scenario Design (v1.1)

Author: brainstorming session with user (linyilun), continued from agent `a214b28faae08cf48`
Date: 2026-04-23
Status: v1.1 — incorporates code-review findings (5 blocking fixes + 5 non-blocking refinements)
Branch: `feature/pr7-e2e` (off `origin/main` = PR-6 snapshot `4edf23d`)

### Changelog
- **v1.1 (2026-04-23)** — code-review pass. Fixes: (1) §4.2 acknowledges full `channel_adapter` plumbing (struct field + SessionRouter seed + PeerFactory thread) and splits Task D into D1/D2; (2) §3.4 tmux session name corrected from `esr-<ULID>` to `esr_cc_<int>` + introspection-call path; (3) §3.5 added — `tmux_socket` env→Application-env→PeerFactory merge path; (4) §13 grep is now case-insensitive, adds sanitization tasks K1/K2 for `tools.py` and cc_proxy/cc_process docstrings; (5) §5.1 calls out the pre-existing `msg_id` / `message_id` key-name bug in `peer_server.ex:734` and folds the fix into D2. Non-blocking: §15 task ordering pins T0 wire-contract first, D1 before D2, K1/K2 split; §7 teardown adds `.sidecar.pid` + `esr-worker-*.pid` + CI-only `pkill erlexec`; §10 drops `feishu-to-cc.yaml` in favor of reusing `simple.yaml`; §7 "A didn't block B" renamed to "session isolation under concurrent load"; §13 item 3 reworded to acknowledge bridging steps; §11 Makefile fragment inlined; §10 cross-refs `runtime/lib/esr/admin/commands/session/new.ex` for `/new-session` dispatch.
- **v1.0 (2026-04-23)** — initial draft from brainstorm.
Relates to:
- `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md` — architectural parent (Peer/Session refactor v3.1)
- `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/docs/superpowers/progress/2026-04-23-pr6-snapshot.md` §"Known unknowns" #3 — PR-7 scope entry
- `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/scenarios/e2e-feishu-cc.yaml` — v0.1 YAML scenario the bash scripts supersede
- `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/scenarios/e2e-esr-channel.yaml` — v0.2 YAML scenario we inherit orchestration primitives from

---

## 1. Overview

### 1.1 Goal

Replace/augment the YAML-driven scenario rig under
`/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/scenarios/`
with three bash scripts that exercise the complete Feishu ↔ CC business
topology end-to-end against a running `esrd` + `mock_feishu`. The rig
must be:

1. **Self-contained** — a contributor runs `make e2e` and, within a
   single wall-clock window, sees all 12 user-steps executed across
   three scenarios.
2. **Deterministic** — every state transition we assert on is driven by
   a barrier file or a synchronous CLI call, not a race-prone `sleep`.
3. **Implementation-ready** — the plan that follows this spec is
   mechanical decomposition: one task per script, one task per
   production-code hook (`send_file` directive), one task per mock
   endpoint (`react`, `send_file`), one task per CI wiring (`make e2e`).

### 1.2 Non-goals

- **No live Feishu credentials.** All three scenarios run against
  `scripts/mock_feishu.py`. A `--live` flag or a live-cred PR is
  explicitly out of scope; see the PR-6 snapshot §"Known unknowns" #4
  for that separate backlog item.
- **No new agent types.** The scenarios exercise the existing `cc`
  agent (agents.yaml `cc` entry with full CC chain). No gemini-cli,
  codex, or voice variants.
- **No cross-esrd routing.** Single-node `esrd` only, per the parent
  spec §1.4.
- **No replacement of the existing YAML scenarios.** Phase-8 gates
  (`final_gate.sh --mock`) continue to consume
  `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/scenarios/e2e-feishu-cc.yaml`
  and `.../e2e-esr-channel.yaml`. The new bash scripts are additive and
  target the PR-7 scope specifically: a business-topology smoke, not a
  runtime-API conformance gate.

### 1.3 Scope

In scope for PR-7:

1. Three bash scripts under
   `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/tests/e2e/scenarios/`:
   - `01_single_user_create_and_end.sh` — Tracks A, end-to-end happy path.
   - `02_two_users_concurrent.sh` — N=2 isolation (parallel subshells).
   - `03_tmux_attach_edit.sh` — tmux attach + tmux pane edit roundtrip.
2. One shared preamble at
   `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/tests/e2e/scenarios/common.sh`
   (env bootstrap + shared assertion helpers).
3. Two new `mock_feishu` endpoints (`react`, `send_file`) documented in §5.
4. One production-code change: `send_file` directive handler in
   `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/adapters/feishu/src/esr_feishu/adapter.py`
   per the α (base64 in-band) wire shape documented in §6.
5. One capability/architectural fix: decouple the CC-side `send_file`
   tool-to-emit mapping from a hardcoded `"adapter" => "feishu"` (§4).
6. **(v1.1 — revised)** No new agent-YAML fixture. `common.sh`
   copies the existing `runtime/test/esr/fixtures/agents/simple.yaml`
   into `${ESRD_HOME}/default/agents.yaml` and overrides `app_id`
   via `/new-session` params. See §10.
7. One Makefile target: `make e2e` — **(v1.1)** targets inlined into
   the top-level `Makefile` (no sourced fragment). See §11.

Out of scope (deferred to follow-ups, logged in §11):

- Live Feishu smoke (post-PR-7, needs real credentials + self-hosted esrd).
- Absolute-zero cleanup mode reuse by live-channel tests.
- Voice-channel E2E (covered by `voice-e2e` agent's own scenario; not here).

---

## 2. Architectural invariant — ESR's CC channel stays adapter-agnostic

**This is the load-bearing user clarification** of the brainstorm.
Codifying it here so the subagent review and the subsequent
plan/implementation honour it:

> ESR's CC channel (`esr_cc_mcp` + the CC chain peers
> `FeishuChatProxy → CCProxy → CCProcess → TmuxProcess`) is the
> abstraction boundary between "AI agent speaks to a channel" and "this
> channel happens to be Feishu." No code reachable by CC — MCP tool
> schemas, peer emit builders, capability declarations — may reference
> `feishu` by name. The adapter identity is a runtime attribute of the
> session / the directive, not a compile-time property of the CC channel.

Two concrete consequences (both must land in PR-7):

1. **Production-code fix**.
   `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr/peer_server.ex`
   currently hardcodes `"adapter" => "feishu"` inside
   `build_emit_for_tool("reply", ...)`,
   `build_emit_for_tool("react", ...)`, and
   `build_emit_for_tool("send_file", ...)` (lines 716, 732, 748).
   That hardcode is the single violation today. PR-7 replaces those
   three literals with a lookup on the session's bound channel adapter,
   sourced from `state` (session metadata carries the agent's declared
   `proxies[].target` — `feishu_app_adapter_${app_id}` for the `cc`
   agent). The directive shape itself is unchanged.
2. **Agent-YAML fixture reuse (v1.1)**. v1.0 proposed a new
   `feishu-to-cc.yaml`. Code-review: near-100% duplicate of existing
   `simple.yaml`. v1.1 reuses `simple.yaml` directly (§10). The
   "Feishu-to-CC" name lives only in this spec and in script
   filenames — not in any fixture or agent YAML. The agent entry
   remains the standard `cc` agent; the Feishu identity is a runtime
   attribute (via `proxies[].target` → `channel_adapter`), not a
   compile-time property of the `cc` agent definition.

Violation of (1) or (2) must block PR-7 merge. The subagent review
should confirm the adapter-agnostic property by grep-proving that no
file under
`/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/adapters/cc_mcp/`
or
`/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr/peers/cc_*.ex`
mentions `feishu` after the fix lands.

---

## 3. Script layout

All paths below are absolute from the worktree root.

```
/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/tests/e2e/
├── scenarios/
│   ├── common.sh              # env + helpers + trap-based teardown
│   ├── 01_single_user_create_and_end.sh
│   ├── 02_two_users_concurrent.sh
│   └── 03_tmux_attach_edit.sh
└── fixtures/
    └── probe_file.txt         # small text blob the send_file step uploads
```

**v1.1**: The top-level `Makefile` embeds the e2e targets directly (no
`Makefile-fragment` sourced). Ambiguity-removal — less magic — see
§11.1.

### 3.1 `common.sh`

Provides:

- **Env bootstrap**. Exports `ESR_E2E_RUN_ID=pr7-$(date +%s)-$$`,
  `ESRD_INSTANCE=e2e-${ESR_E2E_RUN_ID}`, `ESRD_HOME=/tmp/esrd-${ESR_E2E_RUN_ID}`,
  `MOCK_FEISHU_PORT=8201` (avoids collision with YAML rig's 8101),
  `ESR_E2E_BARRIER_DIR=/tmp/esr-e2e-${ESR_E2E_RUN_ID}/barriers`,
  `ESR_E2E_UPLOADS_DIR=${ESRD_HOME}/default/uploads`.
- **Assertion helpers** (see §8 for the full catalogue):
  - `assert_eq "$actual" "$expected" "<context msg>"` — echo-and-exit on
    mismatch with a contextual error (knob **(a)**: per-assertion
    messages).
  - `assert_contains "$haystack" "$needle" "<context>"`.
  - `assert_not_contains` (inverse).
  - `assert_ok <cmd>…` — runs, exits non-zero if the command failed.
  - `assert_file_exists`, `assert_file_absent`.
- **Barrier primitives** (sync primitives β from brainstorm):
  - `barrier_wait <name> [timeout_s=30]` — polls
    `${ESR_E2E_BARRIER_DIR}/${name}` with `sleep 0.2` until it exists
    or `timeout_s` elapses; exits 1 on timeout.
  - `barrier_signal <name>` — `touch
    "${ESR_E2E_BARRIER_DIR}/${name}"`.
- **Trap setup** (knob **(b)**: trap-based failure asserts):
  ```bash
  set -Eeuo pipefail
  trap '_on_err $? $LINENO' ERR
  trap '_on_exit' EXIT
  ```
  `_on_err` prints the failing line + run-id + mock-feishu log tail
  then falls through to `_on_exit`. `_on_exit` runs the teardown
  sequence regardless of success/failure.
- **One-shot setup helpers** (`start_esrd`, `start_mock_feishu`,
  `register_feishu_adapter`, `load_agent_yaml`) that each barrier-wait
  on the component's readiness signal before returning.

### 3.2 `01_single_user_create_and_end.sh`

User-steps covered (from the 12-step list; see §9 for the full matrix):
1. Create session via `/new-session esr-dev tag=single`.
2. Send a plain message → CC sees inbound → CC calls `reply` tool.
3. CC calls `react` tool on the user's original message.
4. CC calls `send_file` tool (tests the new directive).
5. End session via `/end-session single` (or `esr cmd stop`).
6. Cleanup assertions — see §7.

### 3.3 `02_two_users_concurrent.sh`

User-steps covered:
7. Two bash subshells spawn concurrently, each creating a session
   (`tag=alpha` in chat `oc_mock_A`, `tag=beta` in chat `oc_mock_B`).
8. Each sends a distinct probe phrase; the scenario asserts that
   `oc_mock_A`'s outbound messages contain only alpha's phrase and
   `oc_mock_B`'s contain only beta's — proving session isolation
   under concurrency.
9. Both subshells end their sessions; parent waits (sync primitive α:
   `wait $pid_a $pid_b`) and cleanup assertions run once joined.

Concurrent milestones that need barriers (β, per user decision
"bash subshells + wait (α) + targeted barrier files (β) at concurrent
milestones"):

- `session_ready_${tag}` — signalled by each subshell after its
  `esr cmd run` returns + `esr actors list` shows its cc:<tag> peer.
  The *other* subshell does **not** wait on this; it's for the parent's
  "both ready before probe" gate.
- `probe_sent_${tag}` — signalled after each subshell's inbound
  `/push_inbound` returns 200. The session-end step waits for both.

**Invariant under test (renamed in v1.1)**. The invariant this script
proves is **session isolation under concurrent load** — alpha's
outbound stream contains no beta content, and vice versa, even when
both sessions run simultaneously. The earlier framing "A didn't block
B" implied a timing/latency assertion that the script does not
actually exercise (the barrier-sync path short-circuits any real
blocking measurement). If a timing assertion is ever needed, capture
`start_ms=$(date +%s%N)` around the joined subshells and compare
against a single-session baseline from `01_single_user_create_and_end.sh`
— but that's a follow-up, not PR-7 scope.

### 3.4 `03_tmux_attach_edit.sh`

User-steps covered:
10. Create session `tag=tmux`.
11. Resolve the live tmux session name (see "tmux session-name
    resolution" below); `tmux attach-session -t ${TMUX_SESSION_NAME}`;
    send keys (`tmux send-keys -t <pane> 'echo hello-tmux' Enter`); read
    the pane via `tmux capture-pane -p`; assert `hello-tmux` appears.
12. Detach + end-session; knob **(d)**: the trap runs
    `tmux kill-session -t ${TMUX_SESSION_NAME}` before global teardown
    so leftover tmux servers from a crashed mid-script state don't
    stall the next run.

**tmux session-name resolution (corrected — v1.1)**.
`runtime/lib/esr/peers/tmux_process.ex:73` generates the session name as:

```elixir
name = "esr_cc_#{:erlang.unique_integer([:positive])}"
```

— prefix is `esr_cc_`, suffix is a non-deterministic Erlang monotonic
integer, **not** a ULID. The script therefore **cannot** derive the
tmux session name from the ESR session ULID. It must query it at
runtime.

Resolution path (chosen — option A, introspection-call):

1. `03_tmux_attach_edit.sh` creates the session and captures its
   ULID from `esr actors list --json`.
2. The script then calls a runtime-introspection CLI —
   `esr actors inspect <actor_id> --field state.session_name` — against
   the session's `tmux_process` peer. The peer's handler module returns
   a describe/snapshot map (PeerServer already supports `describe/1` —
   `peer_server.ex:97`), and the CLI surfaces the `state.session_name`
   slot.
3. If `esr actors inspect` does not currently surface that field, add a
   **pre-req micro-task** to the task list: extend `EsrWeb.CliChannel`
   (or the closest equivalent) so `cli:actors/inspect <actor_id>
   --field <k>` returns the value. Implementation is a one-liner —
   `get_in(state, String.split(field, "."))` — because `describe/1`
   already returns the state map.
4. Fallback: if extending `esr actors inspect` is out of scope, the
   script may fall back to `tmux ls -F '#S'` under
   `$ESR_E2E_TMUX_SOCK` and pick the single `esr_cc_*` entry (run-scoped
   socket guarantees exactly one). This fallback is documented here but
   **not** the default — it relies on one-session-per-socket, which
   scenario 02 explicitly violates (two concurrent sessions share one
   mock_feishu but may share one tmux socket too).

Rejected alternative (option B — put the ULID into the session name by
editing `tmux_process.ex:73`): would require changing the session-name
format, breaking any existing test that pattern-matches `esr_cc_<int>`
and any downstream tooling that parses the name. Non-invasive
introspection (option A) is preferred.

### 3.5 Threading `tmux_socket` from script → `TmuxProcess` (v1.1)

Originally implicit in §3.4 — explicit in v1.1. `tmux_process.ex:76-79`
accepts an optional `:tmux_socket` param in `spawn_args`, but v1.0 did
not say how the script's `$ESR_E2E_TMUX_SOCK` env var reaches that
param. The plumbing path (chosen — Application-env + PeerFactory merge,
option A below):

1. `common.sh::start_esrd` sets `ESR_E2E_TMUX_SOCK=/tmp/esr-e2e-${ESR_E2E_RUN_ID}/tmux.sock`
   in its exported env before spawning `esrd`.
2. Add a tiny reader at esrd boot (pick an early lifecycle hook — e.g.
   `Esr.Application.start/2` or a dedicated `Esr.Boot.Env`) that reads
   `System.get_env("ESR_E2E_TMUX_SOCK")` and, when non-empty, stashes
   it via:
   ```elixir
   Application.put_env(:esr, :tmux_socket_override, socket_path)
   ```
3. `TmuxProcess.spawn_args/1` (tmux_process.ex:68) merges the override
   when the caller did not explicitly pass `:tmux_socket`:
   ```elixir
   case Esr.Peer.get_param(params, :tmux_socket) ||
          Application.get_env(:esr, :tmux_socket_override) do
     nil  -> base
     path -> Map.put(base, :tmux_socket, path)
   end
   ```
   Explicit caller-provided value still wins — override is a last
   resort for env-driven test rigs only.
4. Scenarios 01, 02, 03 all inherit the socket because the env var
   crosses the process boundary at esrd boot; no per-spawn plumbing.

Rejected alternative (option B — YAML templating of `params.tmux_socket`
as `${ENV.ESR_E2E_TMUX_SOCK}`): would add a new fixture-format feature
that `Esr.SessionRegistry.agent_def/1` would need to understand. Too
heavy a lift for a test-only concern.

This plumbing is a **pre-req** for `03_tmux_attach_edit.sh` working
under a run-scoped socket. Tracked as its own task — see §15 Task J1.

---

## 4. Production adapter extensions

### 4.1 `esr_feishu` adapter: add `send_file` directive handler

File:
`/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/adapters/feishu/src/esr_feishu/adapter.py`

Current state: `on_directive` (line 329) dispatches `send_message`,
`react`, `send_card`, `pin`, `unpin`, `download_file`. There is **no**
outbound `send_file`. (The existing `_download_file` at line 504
handles the **inbound** direction — Feishu → local uploads dir —
opposite of what CC's `send_file` tool means.)

Add a new branch:

```python
if action == "send_file":
    return await self._with_ratelimit_retry(lambda: self._send_file(args))
```

Plus a `_send_file(args)` method honouring the α wire shape — see §6.

### 4.2 ESR CC-chain: unhardcode adapter name (v1.1 — full plumbing)

**v1.0 framed this as a 5-line helper. The code-review turned up
real plumbing work.** The `PeerServer` struct (peer_server.ex:42–57)
has no `:channel_adapter` field; `grep channel_adapter runtime/`
returns 0 hits today; no code path seeds the value. The fix is
therefore **two tasks**, not one, and the helper call in
`build_emit_for_tool/3` is the *last* line to change, not the first.

File:
`/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr/peer_server.ex`

Lines 709–756 (`build_emit_for_tool/3` for `"reply"`, `"react"`,
`"send_file"`) currently literal-in `"adapter" => "feishu"`. The
replacement helper:

```elixir
defp session_channel_adapter(%__MODULE__{state: thread_state}) do
  Map.get(thread_state, "channel_adapter", "feishu")
end
```

...needs a live `state.channel_adapter` slot to read. The plumbing to
deliver one is:

**(a) Add a `:channel_adapter` field on the `PeerServer` struct**
(peer_server.ex:42). Optional — since the helper reads from
`state.state` (the "thread state" map inside the PeerServer state,
seeded per-peer) rather than the struct itself, we can put the value
inside the thread-state map and skip the struct field. Pick one:
- **(a1)** Thread-state map slot (`state["channel_adapter"]`). Simpler;
  no struct change. Seeded by each peer's `init/1` when relevant.
- **(a2)** Dedicated struct field on `PeerServer`. Typed; discoverable
  in `describe/1`; but every peer init path has to be updated.

**Choice: (a1)**. The helper signature above already reads from the
thread-state map, and existing session-scoped fields (`chat_id`,
`thread_id`) live there too — follows the prevailing convention.

**(b) Thread `channel_adapter` through the session-spawn params** so
`SessionRouter.do_create/1` (session_router.ex:247) sees it.

The agent YAML already carries the authoritative source in the
`proxies[].target` string:

```yaml
proxies:
  - name: feishu_app_proxy
    impl: Esr.Peers.FeishuAppProxy
    target: "admin::feishu_app_adapter_${app_id}"
```

**Parsing contract (formalised in v1.1)**:
```
target := "admin::<adapter_family>_adapter_<app_id>"
regex  := ~r/^admin::([a-z_]+)_adapter_.*$/
```

`<adapter_family>` is the adapter name (e.g. `feishu`, `slack`,
`discord`). Non-matching targets fall back to `"feishu"` with a
`Logger.warning("channel_adapter: non-matching proxy target target=... falling back to feishu")`.

Parsing lives in `SessionRouter.do_create/1` (session_router.ex:247).
Extract the first matching proxy's adapter family and attach it to
`params` under key `:channel_adapter` **before** `spawn_pipeline/3` is
called. `build_ctx/2` (session_router.ex:363) for `Esr.Peers.FeishuAppProxy`
already expands `${app_id}` — the v1.1 change expands the **adapter
family** at the same time.

**(c) Propagate into the spawn path**.
`Esr.PeerFactory.spawn_peer/5` (peer_factory.ex:21) receives the
`ctx` map already. The `FeishuChatProxy` peer's `init/1` copies
`ctx.channel_adapter` into its thread-state map:

```elixir
%{
  ...existing fields...,
  "channel_adapter" => Map.get(ctx, :channel_adapter) || "feishu"
}
```

Downstream CC-chain peers that need the value (CCProxy, CCProcess,
PeerServer instances wrapping those) copy it forward on every state
transition — matching the existing `chat_id`/`thread_id` propagation
pattern.

**(d) Consume in `build_emit_for_tool`**. Only *after* (a)–(c) land
does the three-line fix in `peer_server.ex:716,732,748` become safe.
Replace each `"adapter" => "feishu"` literal with:

```elixir
"adapter" => session_channel_adapter(state),
```

and change the function signature `build_emit_for_tool("reply", args,
_state)` to `build_emit_for_tool("reply", args, state)` (drop the
underscore on the three affected clauses — currently the state is
unused on these three branches).

**Fallback semantics**. `session_channel_adapter/1` returns `"feishu"`
when the thread-state key is missing. This covers: (i) sessions created
before the PR-7 seed path lands; (ii) agents whose proxy target
doesn't match the regex (logged as warning per above). The fallback
is deprecated and logged as a follow-up (§14 item 2) — removed in the
next refactor after two CI runs confirm the seeded path is live.

**Grep verification** (runs in the subagent review loop and again in
CI): case-insensitive grep — see §13 item 4 for the updated sanitation
criterion.

This is spread across the task list as **D1 (plumbing: struct/state,
SessionRouter seed, PeerFactory thread, FeishuChatProxy copy)** and
**D2 (peer_server.ex consumption + the `msg_id` key-name fix — §5.1)**.
D2 depends on D1. See §15.

---

## 5. Mock Feishu extensions — wire contracts

File:
`/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/scripts/mock_feishu.py`

### 5.1 New endpoint: `POST /open-apis/im/v1/messages/:message_id/reactions`

Purpose: receive reaction creates emitted by `_react` in the adapter
(line 429 in adapter.py). Today, `_react` calls
`im.v1.message.reaction.create` against the real Lark API; in mock
mode there is no interception path. We give mock_feishu an endpoint at
the Lark-compatible URL *and* a scenario-friendly sibling.

Wire contract:

```
POST /open-apis/im/v1/messages/<message_id>/reactions
Body: {"reaction_type": {"emoji_type": "THUMBSUP"}}
Response: {"code": 0, "msg": "", "data": {"reaction_id": "rc_mock_<hex>", "message_id": "<message_id>"}}
```

Additionally, for scenario grep-ability:

```
GET /reactions
Response: [{"message_id": "<id>", "emoji_type": "THUMBSUP", "ts_unix_ms": 17...}, ...]
```

Reaction records accumulate in a `self._reactions: list[dict]` in
`MockFeishu.__init__` and are exposed by the GET endpoint exactly like
`/sent_messages` is exposed today (adapter.py mirrors the existing
`_send_message_mock` pattern).

**Adapter hook for the mock path**. Today, `_react` in adapter.py does
not have a mock branch (unlike `_send_message`). The adapter-side fix
is small: detect `base_url` starting with `http://127.0.0.1` /
`http://localhost` (same sniff as `_send_message_mock`) and POST to
`f"{base_url}/open-apis/im/v1/messages/{msg_id}/reactions"` instead of
invoking `lark_oapi`. This is a production-code extension co-scoped
with PR-7 because otherwise `react` has no testable mock path at all.

**Pre-existing `_react` key-name bug — fix in v1.1 (co-scoped with §4.2 D2)**.
Code-review finding: `peer_server.ex:734` emits the arg map:

```elixir
"args" => %{"message_id" => mid, "emoji_type" => emoji}
```

but `adapter.py:433` reads:

```python
msg_id = args["msg_id"]
```

Different keys (`message_id` vs `msg_id`). Today nothing exercises this
path because no session has ever triggered a `react` emit through the
mock. PR-7 is the first scenario that would — and it would break on
a `KeyError` inside the adapter.

**Decision: fix at the Elixir source.** Change `peer_server.ex:734`
emit key from `"message_id"` → `"msg_id"`. Rationale: adapter.py's
`msg_id` matches the existing cc-openclaw Feishu adapter convention
(verified in the adapter's other handlers — lines 482, 497, 513, all
consume `args["msg_id"]`). The Elixir side is the sole outlier.

Concretely:

```elixir
# peer_server.ex:726–740 (after v1.1)
defp build_emit_for_tool("react", args, state) do
  case args do
    %{"message_id" => mid, "emoji_type" => emoji} ->
      {:ok,
       %{
         "type" => "emit",
         "adapter" => session_channel_adapter(state),
         "action" => "react",
         "args" => %{"msg_id" => mid, "emoji_type" => emoji}  # ← was "message_id"
       }}
    _ ->
      {:error, "react requires message_id + emoji_type"}
  end
end
```

Input key (what CC's MCP tool layer passes in `args`) stays
`"message_id"` — no CC-side change. Only the emit payload's key
changes.

This is a **sub-step of Task D2** (§15) because it lives in the same
file and touches the same emit builder as the D2 work.

### 5.2 New endpoint: `POST /open-apis/im/v1/files` + `POST /open-apis/im/v1/messages` with `msg_type=file`

Purpose: receive file uploads from the new `_send_file` directive (§6).

Wire contract:

```
Step 1 — upload:
POST /open-apis/im/v1/files
Body (multipart/form-data OR application/json with base64 payload — see §6.1):
  file_type: "stream"
  file_name: "probe.txt"
  file:      <raw bytes or base64 depending on α/β shape>
Response: {"code": 0, "msg": "", "data": {"file_key": "file_mock_<hex>"}}

Step 2 — send-as-message (reuses existing endpoint):
POST /open-apis/im/v1/messages?receive_id_type=chat_id
Body: {"receive_id": "oc_xxx", "msg_type": "file",
       "content": "{\"file_key\": \"file_mock_<hex>\"}"}
Response: same as existing send_message response.
```

Scenario-grep sibling:

```
GET /sent_files
Response: [{"chat_id": "oc_xxx", "file_key": "file_mock_<hex>",
            "file_name": "probe.txt", "size": N, "sha256": "...",
            "ts_unix_ms": 17...}, ...]
```

Mock_feishu persists the uploaded bytes under `/tmp/mock-feishu-files-${port}/<file_key>`
so assertions can compare bytes end-to-end if ever needed. The sha256
field is computed at upload time and included in `/sent_files` for
tamper-detection in assertions (knob **(c)**: baseline-diff — uploaded
file sha matches local fixture's sha, not "the uploads dir is empty").

### 5.3 No changes to existing endpoints

`/push_inbound`, `/sent_messages`, `/open-apis/im/v1/messages` (POST
+ GET), `/ws` retain their current contracts unchanged.

---

## 6. `send_file` directive wire shape — α base64 in-band

**User decision**: α (base64 in-band), confirmed. β (pre-upload +
file_key reference) is deferred to a follow-up that needs large-file
support; PR-7 probe is a ~1 KB text blob so base64 overhead is trivial.

### 6.1 α wire shape

The CC chain emits:

```json
{
  "type": "emit",
  "adapter": "<runtime-resolved channel adapter>",
  "action": "send_file",
  "args": {
    "chat_id": "oc_xxx",
    "file_name": "probe.txt",
    "content_b64": "SGVsbG8gUFItNyE=",
    "sha256": "<hex sha of the decoded bytes>"
  }
}
```

- `file_name` comes from `basename(file_path)` in CC's `send_file` tool
  emit builder; it is authoritative for display in Feishu.
- `content_b64` is standard base64 (RFC 4648) of the file bytes.
- `sha256` is computed over the **decoded** bytes by the CC chain
  before encoding. The adapter re-computes on the decoded side and
  rejects mismatches with `{"ok": False, "error": "sha256 mismatch"}`
  — protects against mid-transit corruption in mock mode (no network
  between CC process and adapter, but MuonTrap-buffered JSON over
  stdin is still a theoretical corruption surface).

### 6.2 CC chain emit builder — updated shape

`/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr/peer_server.ex`
line 742's `build_emit_for_tool("send_file", args, _state)` currently
emits:

```elixir
%{"chat_id" => cid, "file_path" => fp}
```

Must change to:

```elixir
case File.read(fp) do
  {:ok, bytes} ->
    {:ok,
     %{
       "type" => "emit",
       "adapter" => session_channel_adapter(state),
       "action" => "send_file",
       "args" => %{
         "chat_id" => cid,
         "file_name" => Path.basename(fp),
         "content_b64" => Base.encode64(bytes),
         "sha256" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
       }
     }}
  {:error, reason} ->
    {:error, "send_file cannot read #{fp}: #{inspect(reason)}"}
end
```

This keeps the tool's **input** schema (CC SDK sees `chat_id +
file_path`) identical to today's
`/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/adapters/cc_mcp/src/esr_cc_mcp/tools.py:47-61`
— no MCP schema change. The encoding happens runtime-side.

### 6.3 Adapter-side `_send_file` implementation

In `adapter.py`, new method:

```python
def _send_file(self, args: dict[str, Any]) -> dict[str, Any]:
    import base64, hashlib
    chat_id = args["chat_id"]
    file_name = args["file_name"]
    content_b64 = args["content_b64"]
    expected_sha = args["sha256"]

    try:
        bytes_ = base64.b64decode(content_b64, validate=True)
    except Exception as exc:
        return {"ok": False, "error": f"b64 decode failed: {exc}"}

    actual_sha = hashlib.sha256(bytes_).hexdigest()
    if actual_sha != expected_sha:
        return {"ok": False, "error": "sha256 mismatch"}

    base_url = getattr(self._config, "base_url", "")
    if base_url.startswith(("http://127.0.0.1", "http://localhost")):
        return self._send_file_mock(base_url, chat_id, file_name, bytes_)

    # Live path: two-step lark_oapi upload + message-create. Unused in
    # PR-7 (mock-only), but coded for parity with _send_message.
    return self._send_file_live(chat_id, file_name, bytes_)
```

`_send_file_mock` POSTs bytes to `mock_feishu`'s `/open-apis/im/v1/files`
(§5.2 step 1), then calls `/open-apis/im/v1/messages` with
`msg_type=file` (§5.2 step 2), mirroring the `_send_message_mock`
pattern (adapter.py line 407).

---

## 7. Cleanup scope

Two modes, per user decision:

### 7.1 Default — run-scoped cleanup

Every artefact the rig creates is under either
`${ESRD_HOME}` (= `/tmp/esrd-${ESR_E2E_RUN_ID}`) or
`${ESR_E2E_BARRIER_DIR}` (= `/tmp/esr-e2e-${ESR_E2E_RUN_ID}/…`) or
`/tmp/mock-feishu-files-${MOCK_FEISHU_PORT}`. The trap teardown:

1. `esr drain` (best-effort, 10 s timeout) — kills live sessions.
2. `bash scripts/esrd.sh stop --instance=${ESRD_INSTANCE}`.
3. `kill -9 $(cat /tmp/mock-feishu-${ESR_E2E_RUN_ID}.pid)` + `rm` pid file.
4. `tmux kill-server` on *each* tmux socket the rig spawned (knob **(d)**).
5. `rm -rf ${ESRD_HOME} ${ESR_E2E_BARRIER_DIR} /tmp/mock-feishu-files-${MOCK_FEISHU_PORT}`.
6. **(v1.1)** `rm -f /tmp/.sidecar.pid` — the sidecar runtime pidfile
   added in commit `bd0f133` (now `.gitignore`-listed). Stale entry
   confuses subsequent `make e2e` runs that start the sidecar.
7. **(v1.1)** `rm -f /tmp/esr-worker-*.pid` — WorkerSupervisor
   pidfiles. Run-scoped prefix is not in use today; the glob is safe
   because each `make e2e` invocation re-creates these.

Parallel runs from the same host are safe — every path carries the
`${ESR_E2E_RUN_ID}` qualifier. This is the default a developer sees
running `make e2e`.

### 7.2 `ESR_E2E_CI=1` — absolute cleanup

CI mode additionally runs:

- `rm -rf /tmp/esrd-e2e-*` (any stale run dirs from previous CI runs
  that crashed mid-teardown).
- `rm -rf /tmp/esr-e2e-*`, `/tmp/mock-feishu-files-*`.
- `pkill -f "mock_feishu.py --port 82"` (CI-only — blunt but defensible
  since CI is a fresh VM).
- `tmux kill-server` against the default socket (CI is fresh; no user
  tmux to protect).
- **(v1.1)** `pkill -f "erlexec.*esr"` — safety net for orphaned
  erlexec children from a crashed esrd. **CI-only** because on a dev
  host this would nuke the user's other erlexec sessions (any other
  Elixir app using `exexec`/`erlexec`).
- **(v1.1)** `rm -f /tmp/esr-worker-*.pid` (already in §7.1 default
  teardown, repeated here for an explicit reset on stale CI workers).

Activated by `make e2e-ci` (the Makefile sets `ESR_E2E_CI=1` and
forwards to `make e2e`).

Cleanup is idempotent: running the trap twice is a no-op. Knob **(c)**:
cleanup *assertions* are baseline-diff, not absolute-zero. We capture
a baseline snapshot of `/tmp` contents before `start_esrd` and after
teardown, and assert that the only new entries are files the rig
explicitly created — not "tmp is pristine", which would fail any
multi-user dev box.

---

## 8. Assertion set — five bash commands per scenario

Per-assertion knobs:
- **(a)** Per-assertion error messages — all helpers take a third
  `<context>` arg.
- **(b)** Trap-based failure asserts — ERR/EXIT traps capture the
  failing line + run-id + tail of `mock_feishu.log` and re-raise.
- **(c)** Baseline-diff — cleanup and uploads-dir asserts compare to a
  baseline snapshot rather than asserting "must be empty".
- **(d)** Tmux cleanup at end — `tmux kill-session -t esr-<sid>`
  before global teardown.

The five bash commands each scenario invokes (shared helper set, every
scenario uses all five at least once):

### 8.1 `assert_actors_list_has <actor_id_substr>` / `assert_actors_list_lacks`

Wraps `uv run --project py esr actors list`. The `--json` flag is used
when shape-matching against a ULID; the plain output is used for
`grep` substring matches. Error message on failure:

```
FAIL [${FUNCNAME}] expected actors-list to contain '<substr>'; got:
<full 'esr actors list' output>
run_id=${ESR_E2E_RUN_ID} line=${BASH_LINENO}
```

### 8.2 `assert_mock_feishu_sent_includes <chat_id> <text_substr>`

```bash
curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/sent_messages" \
  | jq -e --arg cid "$1" --arg txt "$2" \
    '.[] | select(.receive_id==$cid) | .content | contains($txt)' >/dev/null \
  || _fail_with_context "expected mock_feishu.sent_messages for $1 to include '$2'"
```

### 8.3 `assert_mock_feishu_reactions_count <message_id> <expected_count>`

Uses `GET /reactions` (§5.1) and `jq length`. Context message includes
the full reactions array on mismatch.

### 8.4 `assert_mock_feishu_file_sha <chat_id> <expected_sha>`

Uses `GET /sent_files` (§5.2) and selects by `chat_id`. Compares
`.sha256` field to the sha of the local fixture file. This is the
send_file assertion.

### 8.5 `assert_tmux_pane_contains <session_name> <text_substr>`

Uses `tmux capture-pane -p -t <session_name>` and grep. Used by
`03_tmux_attach_edit.sh` only, but lives in `common.sh` so future
scenarios inherit it.

---

## 9. User-step coverage matrix

The 12 user-steps mapped to scenarios:

| # | Step | Script | Assertion helper used |
|---|------|--------|------------------------|
| 1 | User sends `/new-session esr-dev tag=<t>` | 01, 02 (×2), 03 | §8.1 `assert_actors_list_has "cc:<t>"` |
| 2 | User sends plain text; CC receives it | 01, 02 (×2) | §8.2 on CC's `reply` output |
| 3 | CC calls `reply` tool with an ack | 01, 02 (×2) | §8.2 with expected ack substring |
| 4 | CC calls `react` tool on user's msg | 01 | §8.3 reactions_count ≥ 1 |
| 5 | CC calls `send_file` tool | 01 | §8.4 file sha matches `probe_file.txt` |
| 6 | User sends second message; CC picks up same session | 01 | §8.1 + §8.2 (no new peer spawned, reply arrived) |
| 7 | Two users, two sessions, interleaved messages | 02 | §8.2 cross-check — alpha's text absent from beta's sent_messages and vice versa |
| 8 | Concurrent session end (both subshells exit cleanly) | 02 | §8.1 `assert_actors_list_lacks "cc:alpha"` AND `"cc:beta"` |
| 9 | User attaches to tmux pane mid-session | 03 | (no assert — attach is user-side; verified by step 10) |
| 10 | User types in tmux pane; command executes | 03 | §8.5 `assert_tmux_pane_contains` |
| 11 | User detaches and returns via session list | 03 | §8.1 on resume |
| 12 | User ends session; cleanup assertions pass | 01, 02, 03 | §8.1 `_lacks` + baseline-diff `/tmp` check |

All 12 steps covered. All three scripts contribute; no step is
orphaned; no script has more than ~6 steps (keeps each script
<200 LoC).

---

## 10. Agent YAML fixture (v1.1 — reuse `simple.yaml`)

**v1.0 proposed a new fixture `feishu-to-cc.yaml`. Code-review
observation: it's a near-100% duplicate of the existing
`runtime/test/esr/fixtures/agents/simple.yaml`.** The only
differences v1.0 called for were (a) the `app_id` default
(`"e2e-mock"` vs `"default"`) and (b) a cosmetic description. Neither
is worth a fixture-file's maintenance cost.

**Decision (v1.1): drop `feishu-to-cc.yaml`; reuse `simple.yaml`.**

Path:

- `common.sh::load_agent_yaml` copies
  `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/test/esr/fixtures/agents/simple.yaml`
  into `${ESRD_HOME}/default/agents.yaml` before `start_esrd`.
- The `app_id` parameter override (`e2e-mock` vs the fixture default
  `default`) is supplied at session-creation time via the `/new-session`
  command (`runtime/lib/esr/admin/commands/session/new.ex`, see §10.1
  cross-ref).
- "Feishu-to-CC" remains the **scenario vocabulary** in this spec and
  in script filenames, but does not bake into any YAML.

### 10.1 `/new-session` routing — cross-reference

The slash-command `/new-session esr-dev tag=<t>` dispatches through
the admin command registry (the unified registry landed in commit
`a240662`). The module tree:

- Handler: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr/admin/commands/session/new.ex`
- Dispatch: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr/admin/dispatcher.ex`
- Queue: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr/admin/command_queue/watcher.ex`

`session/new.ex` builds the `create_session` params map (including the
`tag` and any `app_id` overrides) and hands it to
`Esr.SessionRouter.create_session/1`. The `create_session` path is the
single entry point for both the manual slash-command and the
`:new_chat_thread` auto-spawn path (session_router.ex:136).

The e2e scripts invoke `/new-session` via `esr cmd run /new-session ...`
or the direct CLI shortcut — either reaches the same `session/new.ex`
handler.

---

## 11. CI integration — `make e2e`

### 11.1 Makefile changes (v1.1 — inline, no fragment include)

File:
`/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/Makefile`

**v1.0 proposed a `tests/e2e/Makefile-fragment` sourced from the
top-level Makefile. Code-review observation: sourced fragments hide
targets from `make -n` discovery and complicate IDE tooling.** v1.1
inlines the targets in the top-level `Makefile` directly:

```makefile
.PHONY: e2e e2e-ci e2e-01 e2e-02 e2e-03

# Run all three scenarios serially. Wall-time budget: <5 min total.
e2e: e2e-01 e2e-02 e2e-03

e2e-01:
	bash tests/e2e/scenarios/01_single_user_create_and_end.sh

e2e-02:
	bash tests/e2e/scenarios/02_two_users_concurrent.sh

e2e-03:
	bash tests/e2e/scenarios/03_tmux_attach_edit.sh

# CI variant: absolute cleanup (§7.2). Same scripts, different env.
e2e-ci:
	ESR_E2E_CI=1 $(MAKE) e2e
```

Each sub-target is standalone and invocable in isolation during
development — a contributor can iterate on scenario 02 without
re-running 01. `make e2e` runs them serially (not in parallel) because
they share one `mock_feishu` port and one esrd instance is simpler to
reason about — concurrency *within* a scenario (script 02's two
subshells) is the concurrency being tested, not concurrency *across*
scenarios.

### 11.2 Wall-time expectation

Budget per script:
- `01_single_user_create_and_end.sh`: ~45 s (esrd cold start 15 s,
  mock_feishu 2 s, scenario body 20 s, teardown 8 s).
- `02_two_users_concurrent.sh`: ~60 s (same setup, two parallel
  subshells overlap, wait-join 5 s).
- `03_tmux_attach_edit.sh`: ~45 s (tmux attach is effectively free
  once the session exists).

Total `make e2e`: **≤ 3 min** typical, **≤ 5 min** hard cap enforced
by a top-level `timeout` wrapper inside each Makefile recipe. Exceeding
the cap is a CI failure — prevents a hung esrd from sitting silently
on GitHub Actions.

### 11.3 CI hook

Separately logged as a follow-up (not in PR-7 scope itself): wire
`make e2e-ci` into the repo's existing CI config. The Phase-8
`final_gate.sh --mock` gate already covers the YAML scenarios; adding
`make e2e-ci` is a config-only change best done after PR-7 merges so
the CI signal reflects the new scripts rather than gating the scripts
on CI adoption. See §12.

---

## 12. CC tool → directive mapping — reminder

CC invokes `send_file` via the MCP tool declared in
`/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/adapters/cc_mcp/src/esr_cc_mcp/tools.py:47-61`.
That tool's input schema
(`{chat_id: string, file_path: string}`) is **already correct** and
requires no change.

The call path today is:

1. CC invokes MCP tool `send_file` with `{chat_id, file_path}`.
2. `esr_cc_mcp` forwards via its WS channel to `Esr.PeerServer`.
3. `Esr.PeerServer.build_emit_for_tool("send_file", args, state)`
   (peer_server.ex:742) today emits the **path-reference** shape —
   needs upgrading to the α base64-in-band shape (§6.2) because the
   adapter process may not share filesystem with the CC process
   (adapter runs under its own sidecar `feishu_adapter_runner`; see
   `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/py/src/feishu_adapter_runner/`).
4. `esr_feishu` adapter's `on_directive("send_file", args)` (new in
   PR-7) handles the decode + mock/live dispatch per §6.3.

The cc-openclaw pattern referenced in the user's brainstorm hint
(MCP `send_file` living in the openclaw-channel server) is the same
shape the ESR `esr_cc_mcp` tool already mirrors — no cross-project
borrow needed; the tool schema is already drop-in compatible per
`adapters/cc_mcp/src/esr_cc_mcp/tools.py` line 5 comment ("API-compatible
per spec §1.1 point 1").

**Summary of new code in PR-7 (v1.1 — revised)**:
- `peer_server.ex`: (D2) update `reply`/`react`/`send_file` emit
  builders to read `session_channel_adapter(state)` (§4.2); fix
  pre-existing `message_id` → `msg_id` key-name bug in the `react`
  emit (§5.1); update `send_file` emit builder to the α base64
  shape (§6.2).
- `session_router.ex`: (D1) parse `proxies[].target` regex,
  thread `:channel_adapter` into the session spawn params/ctx.
- `peer_factory.ex`: (D1) no code change — pass-through via the
  existing `ctx` map (confirmed signature accepts it).
- `feishu_chat_proxy.ex`: (D1) copy `ctx.channel_adapter` into
  thread-state map in `init/1`.
- `tmux_process.ex`: (J1) merge `Application.get_env(:esr,
  :tmux_socket_override)` in `spawn_args/1` when caller did not
  pass `:tmux_socket`.
- `application.ex` (or equivalent boot hook): (J1) read
  `ESR_E2E_TMUX_SOCK` env at boot, stash in Application env.
- `adapter.py`: add `_send_file` + mock/live branches; add `_react`
  mock branch.
- `mock_feishu.py`: add `/reactions` + `/sent_files` + `/files`
  endpoints.
- `tools.py` (cc_mcp): (K1) sanitize 6 "Feishu" mentions to
  adapter-agnostic phrasing.
- `cc_proxy.ex` / `cc_process.ex`: (K2) sanitize docstring
  mentions of `FeishuChatProxy`.
- No new MCP tool, no new adapter interface, no new CC-side code.

---

## 13. Acceptance criteria

PR-7 is ready to merge when **all** of the following hold:

1. `make e2e` passes on a clean checkout of `feature/pr7-e2e` (+ any
   follow-on commits). Wall time ≤ 5 min.
2. `make e2e` passes **again** immediately after, using the same
   checkout — proves cleanup is idempotent and run-scoped (§7.1).
3. **(v1.1 — reworded)** Every user-step (§9) that produces
   observable state has an explicit assertion in scripts 01/02/03.
   Bridging steps — e.g. step 9 "user attaches to tmux pane" — are
   verified by the subsequent state-change step (step 10 asserts
   pane-contents, which is only reachable if step 9 succeeded).
4. **(v1.1 — case-insensitive grep + sanitization)**
   Grep-proof of architectural invariant (§2). Run:
   ```
   grep -irn 'feishu' \
     /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/adapters/cc_mcp/src/ \
     /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr/peers/cc_proxy.ex \
     /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr/peers/cc_process.ex \
     /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr/peers/cc_*.ex
   ```

   **Baseline (pre-PR-7, v1.1 measured)**: 8 matches
   (6 in `adapters/cc_mcp/src/esr_cc_mcp/tools.py` lines
   15, 24, 35, 41, 50, 56; 2 in
   `runtime/lib/esr/peers/cc_proxy.ex:3` and
   `runtime/lib/esr/peers/cc_process.ex:7`).
   **Target (post-PR-7): 0.**

   Sanitization tasks (split into K1 + K2 in §15):

   - **K1** — `adapters/cc_mcp/src/esr_cc_mcp/tools.py`: rewrite the
     6 "Feishu" mentions in tool description strings to
     adapter-agnostic phrasing. Examples:
     - `"Send a message to a Feishu chat"` →
       `"Send a message to the user's chat channel"`.
     - `"Feishu chat ID (oc_xxx)"` →
       `"Channel chat ID (opaque token scoped to the active channel)"`.
     - `"Add an emoji reaction to a Feishu message"` →
       `"Add an emoji reaction to a channel message"`.
     - `"Feishu emoji (THUMBSUP, DONE, OK)"` →
       `"Emoji code (channel-specific; e.g. THUMBSUP, DONE, OK for Feishu)"`.
     - `"Send a file to a Feishu chat..."` →
       `"Send a file to the user's chat channel..."`.

   - **K2** — `runtime/lib/esr/peers/cc_proxy.ex` module docstring
     line 3 + `cc_process.ex` module docstring line 7: drop the
     `FeishuChatProxy` literal. Choice:
     - Rewrite to "the upstream chat proxy" (adapter-agnostic).
     - Or keep the reference but preface with "e.g." to mark it as
       an illustrative example of a chat-adapter-specific upstream
       rather than the contractual one.
     - Pick the first option for consistency with K1.

5. `adapters/feishu/src/esr_feishu/adapter.py::on_directive` dispatches
   `send_file` correctly under pytest (unit test covering α shape +
   sha mismatch rejection). Unit test lives at
   `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/py/tests/adapter_runners/test_feishu_send_file.py`.
6. **(v1.1 — added)** `adapters/feishu/src/esr_feishu/adapter.py::on_directive`
   dispatches `react` correctly under pytest using the corrected
   `msg_id` key (§5.1 pre-existing bug fix). Unit test lives at
   `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/py/tests/adapter_runners/test_feishu_react.py`.
7. All pre-existing tests remain green — `make test` (py + mix)
   unchanged count, no flakes introduced.

---

## 14. Deferred / follow-ups (logged here per user memory `feedback_dont_defer_what_is_solvable_now`)

These are consciously-deferred items with rationale:

1. **Large-file send_file (β shape — pre-upload + file_key reference)**
   — deferred because PR-7 probe is 1 KB; implementing β now doubles
   the mock endpoints with no scenario exercising them. Target: the
   first PR that needs ≥1 MB file transfer.
2. **Remove `"feishu"` fallback in `session_channel_adapter/1`** (§4.2)
   — kept during PR-7 to avoid flakes from sessions created before the
   seed path lands. Target: next refactor PR after two CI runs confirm
   the seeded path is live.
3. **Wire `make e2e-ci` into CI config** — config-only change, best
   done after PR-7 merges. Logged as a tiny follow-up issue.
4. **Live Feishu smoke** — already tracked in PR-5 snapshot §"Known
   unknowns" #4; not re-logged here.
5. **`02_two_users_concurrent.sh` — extend to N=3+** if future concurrency
   stress is needed. For PR-7, N=2 proves isolation; higher N is
   diminishing returns until a specific bug motivates it.

---

## 15. Plan (next phase) — pre-structure (v1.1)

The writing-plans phase (next, after subagent review of this spec)
should decompose along this boundary. v1.1 re-ordered the tasks to
honour the review findings: **T0** pins the wire contracts before any
code moves; **D** is split into **D1** (plumbing) and **D2**
(peer_server emit + `msg_id` fix) with D2 depending on D1; **K** is
split into **K1** (tools.py) + **K2** (peer docstrings); **J1** is the
new tmux_socket plumbing task. Target total: 12–14 tasks.

### 15.1 Task list

- **T0 — Wire-contract sheet (pre-req)**. A single ~100-line doc
  committed before B/C begin, at
  `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/docs/notes/pr7-wire-contracts.md`.
  Pins `POST /open-apis/im/v1/files` + `POST /open-apis/im/v1/messages`
  + `POST /open-apis/im/v1/messages/:message_id/reactions` payload
  shapes, and the `channel_adapter` parsing regex (§4.2). Gates B, C,
  D1 via review checklist item.
- **Task A — `common.sh` + test fixtures**. No Python/Elixir code.
  Includes `tests/e2e/fixtures/probe_file.txt` + the common assertion
  helpers + barrier primitives (§3.1).
- **Task B — mock_feishu endpoints**. `/reactions`, `/files`,
  `/sent_files` endpoints in
  `scripts/mock_feishu.py` + unit tests in
  `scripts/tests/test_mock_feishu.py`. Depends on T0.
- **Task C — adapter.py extensions**. `_send_file` method +
  `_react` mock branch + unit tests under `py/tests/adapter_runners/`.
  Depends on T0. Test files: `test_feishu_send_file.py`,
  `test_feishu_react.py`.
- **Task D1 — `channel_adapter` plumbing (peer_server ← SessionRouter ←
  YAML)**. Thread the value end-to-end (§4.2 steps a–c):
  - Parse regex on `proxies[].target` in
    `SessionRouter.do_create/1`; attach `:channel_adapter` to params.
  - Pass through `spawn_one` → `build_ctx` → `PeerFactory.spawn_peer/5`.
  - `FeishuChatProxy.init/1` copies `ctx.channel_adapter` into its
    thread-state map.
  - Mix tests under `runtime/test/esr/session_router_test.exs` (new
    `channel_adapter` test case covering regex parse + fallback warn).
  Depends on T0.
- **Task D2 — peer_server.ex emit builder fixes + `msg_id` key-name
  fix**. Consume `session_channel_adapter(state)` in the three
  branches (§4.2 step d); change `"message_id"` → `"msg_id"` in the
  react emit (§5.1); update `build_emit_for_tool("send_file", ...)`
  to the α base64 shape (§6.2). Mix tests in
  `runtime/test/esr/peer_server_test.exs`.
  **Depends on D1** (state needs the slot populated before the read
  can be verified).
- **Task J1 — `tmux_socket` env plumbing**. Add the
  `Application.put_env(:esr, :tmux_socket_override, ...)` boot reader
  + the `TmuxProcess.spawn_args/1` merge (§3.5). Mix tests in
  `runtime/test/esr/peers/tmux_process_test.exs`. Pre-req for `03_*`
  script. Independent of D1/D2.
- **Task F — `01_single_user_create_and_end.sh`**. Depends on A, B,
  C, D2 (for `react` assertion), J1 (for tmux_socket env to be
  honoured). Not strictly blocked on K1/K2.
- **Task G — `02_two_users_concurrent.sh`**. Depends on same
  prerequisites as F.
- **Task H — `03_tmux_attach_edit.sh`**. Depends on F/G's helpers +
  J1 + the tmux introspection path (§3.4) — which itself may need a
  tiny `cli:actors/inspect --field` extension, folded into H.
- **Task K1 — sanitize `adapters/cc_mcp/src/esr_cc_mcp/tools.py`**
  (§13 item 4). Rewrite 6 "Feishu" mentions to adapter-agnostic
  phrasing. Py-unit test verifying `@tool` description strings don't
  contain the word `feishu` (case-insensitive).
- **Task K2 — sanitize CC peer docstrings**. Rewrite `FeishuChatProxy`
  mentions in `cc_proxy.ex:3` and `cc_process.ex:7` to "the upstream
  chat proxy". No runtime impact.
- **Task I — Makefile targets + `ESR_E2E_CI` mode + inline (not
  fragment) integration** (§11.1). Depends on F/G/H.
- **Task J — Documentation cross-refs**. `docs/architecture.md` if
  any callers need a pointer to the new topology; README e2e section
  under `tests/e2e/`. Last to land.

### 15.2 Dependency graph

```
T0 → A, B, C, D1
D1 → D2
J1 (independent of everything else)
A + B + C + D2 + J1 → F, G, H
K1, K2 (independent; run any time before I)
F + G + H → I
All → J (docs last)
```

Parallelism windows:
- **Window 1** (after T0): A, B, C, D1, J1, K1, K2 all parallel.
- **Window 2** (after D1): D2.
- **Window 3** (after A+B+C+D2+J1): F, G, H in parallel.
- **Window 4**: I, then J.

Subagent-driven development (the pattern used for PR-1..PR-6) fits
well — each task fits in one subagent turn. Total count: **14
tasks** (T0, A, B, C, D1, D2, J1, F, G, H, K1, K2, I, J).
