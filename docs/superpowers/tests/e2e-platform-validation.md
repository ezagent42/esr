# ESR v0.1 — E2E Platform Validation Specification

**Status:** draft
**Maps to:** design spec §9; implementation plan Phase 8
**Purpose:** validate the **platform**, not just a single business scenario. feishu-to-cc is the exercise vehicle; the platform capabilities are what's under test.

---

## 0. How to read this document

The E2E is organised as eight **Tracks** (A–H), each focused on one platform capability:

| Track | Capability |
|---|---|
| A | Component registration & discovery |
| B | Scheduling & multi-session concurrency (including `/new-thread` in Feishu) |
| C | Bidirectional message flow |
| D | Session isolation |
| E | Observability (trace, telemetry, inspect, logs) |
| F | Operations (stop, drain, restart) |
| G | Debug (replay, inject, pause/resume, OTP restart) |
| H | Correctness & consistency |

Each track has four sections: **Goal** (one sentence), **Preconditions** (what the system needs to look like before the track starts), **Scenario** (numbered observable steps), **Acceptance criteria** (checkboxes the implementer signs off), plus **Failure modes** (what common wrong states look like and where to investigate).

A v0.1 "pass" requires every checkbox in every track to be ticked — no cherry-picking. See §9 of this document for the aggregate success gate.

The executable counterpart — `scenarios/e2e-platform-validation.yaml` — is machine-readable (written in Phase 8). This document is the human-reviewable source of truth; if the YAML and this document diverge, this document wins and the YAML is corrected.

---

## 1. Environment

- Two esrd instances running: `esrd-prod` on `localhost:4000` (daily comms, shared Feishu app) and `esrd-dev` on `localhost:4001` (dev Feishu app). Only `esrd-dev` participates in the E2E.
- `esr use localhost:4001` set in the test shell.
- Feishu dev app credentials available at `~/.esrd/dev/secrets/feishu-dev.json`.
- Fresh slate: `esrd-dev` started with empty registry (no adapters installed, no commands registered, no actors alive).
- `tmux` installed and in `PATH`.
- `claude` CLI installed; a sentinel `./e2e-cc.sh` script serves as the thing `cc_tmux` adapter spawns (so we don't burn through Anthropic quota during E2E).

### Time budget

The entire E2E runs in ≤ 5 minutes on a developer laptop. Anything slower indicates a problem, not a fix-before-merge issue with the test itself.

---

## Track A — Component Registration & Discovery

**Goal:** verify the CLI can install adapters, handlers, and commands, and that the runtime registry reflects each installation.

### Preconditions

- Fresh `esrd-dev` instance running, empty registry
- Working directory: `/Users/h2oslabs/Workspace/esr/` (so relative paths like `./adapters/feishu/` resolve)
- `esr use localhost:4001` set

### Scenario

1. **Install `feishu` adapter module**
   ```bash
   esr adapter install ./adapters/feishu/
   ```
   Expected: CLI prints `installed adapter 'feishu' (v0.1.0)`; telemetry `[:esr, :adapter, :installed]` fires with `name=feishu`.

2. **Install `cc_tmux` adapter module**
   ```bash
   esr adapter install ./adapters/cc_tmux/
   ```

3. **Configure a `feishu-shared` instance of the `feishu` adapter**
   ```bash
   esr adapter add feishu-shared \
     --type feishu \
     --app-id cli_TEST \
     --app-secret FAKE_FOR_E2E
   ```
   Expected: CLI prints `added instance 'feishu-shared'`; `~/.esrd/dev/adapters.yaml` records the instance.

4. **Install handler modules**
   ```bash
   esr handler install ./handlers/feishu_app/
   esr handler install ./handlers/feishu_thread/
   esr handler install ./handlers/tmux_proxy/
   esr handler install ./handlers/cc_session/
   ```

5. **Install command patterns**
   ```bash
   esr cmd install ./patterns/feishu-app-session.py
   esr cmd install ./patterns/feishu-thread-session.py
   ```
   Expected: each install step resolves dependencies (referenced adapters and handlers must already be installed — Tasks 2 + 4 satisfy this). Any missing dep fails with an actionable error: `command X references adapter feishu which is not installed; run 'esr adapter install ./adapters/feishu/'`.

6. **Verify registry reflects everything**
   ```bash
   esr adapter list              # expect 2 types
   esr adapter list --instances  # expect 1 instance
   esr handler list              # expect 4 handlers
   esr cmd list                  # expect 2 commands
   esr status                    # aggregate
   ```

### Acceptance criteria

- [ ] A-1 `esr adapter list` shows exactly: `feishu`, `cc_tmux`
- [ ] A-2 `esr adapter list --instances` shows exactly: `feishu-shared (type=feishu, app_id=cli_TEST)`
- [ ] A-3 `esr handler list` shows: `feishu_app.on_msg`, `feishu_thread.on_msg`, `tmux_proxy.on_msg`, `cc_session.on_msg`
- [ ] A-4 `esr cmd list` shows: `feishu-app-session`, `feishu-thread-session`
- [ ] A-5 `esr status` reports `adapters: 2 installed, 1 instance`, `handlers: 4`, `commands: 2`
- [ ] A-6 Installing a command whose referenced handler is absent fails with the exact error format above (test by uninstalling `feishu_app` then re-installing `feishu-app-session`; expect failure; re-install handler)
- [ ] A-7 End-to-end registration latency < 100 ms per install (observed via `esr telemetry subscribe "esr.*.installed"` timestamps)

### Failure modes

| Symptom | Likely cause | Where to look |
|---|---|---|
| Install hangs > 30 s | Phoenix channel between CLI and runtime down | `curl -v http://localhost:4001/health` (if endpoint exists); `ps aux \| grep beam.smp` |
| Install succeeds but `list` is empty | Registry not persisted | `~/.esrd/dev/{adapters,handlers,commands}.yaml` or the ETS snapshot |
| `cmd install` says dep missing when it isn't | Version or alias mismatch in installed module's manifest | `esr.toml` in the adapter/handler source; compare `name` field against what the pattern references |

---

## Track B — Scheduling & Multi-Session Concurrency

**Goal:** verify the runtime can spawn and co-run multiple session topologies and that `/new-thread` in Feishu triggers sub-topology instantiation idempotently.

### Preconditions

- Track A passed
- Stub Feishu WS listener running (no real Feishu required; a fake that yields pre-recorded `msg_received` events is fine for this track — real Feishu integration is Track C)

### Scenario

1. **Boot the feishu-app-session singleton**
   ```bash
   esr cmd run feishu-app-session \
     --param app_id=cli_TEST \
     --param instance_name=shared
   ```
   Expected: one actor `feishu-app:cli_TEST` alive.

2. **Spawn three thread sub-topologies via CLI**
   ```bash
   for t in t1 t2 t3; do
     esr cmd run feishu-thread-session --param thread_id=$t
   done
   ```
   Expected: for each, three new actors (`thread:<t>`, `tmux:<t>`, `cc:<t>`) spawned in `depends_on` order.

3. **Spawn a fourth thread via simulated Feishu `/new-thread`**
   Inject a synthetic `msg_received` event to the `feishu-app:cli_TEST` actor with content `/new-thread t4`:
   ```bash
   esr debug inject \
     --to feishu-app:cli_TEST \
     --event '{"event_type":"msg_received","args":{"content":"/new-thread t4","msg_id":"m-fake-1"}}'
   ```
   Expected: the feishu_app.on_msg handler returns `InvokeCommand("feishu-thread-session", {"thread_id": "t4"})`; runtime instantiates the sub-topology; three new actors appear within 1 s.

4. **Idempotency test**
   Inject the same `/new-thread t4` message again with a new `msg_id`.
   Expected: no new actors; handler state still has `t4` in `bound_threads`; no duplicate spawn.

5. **List everything**
   ```bash
   esr actors list
   esr actors tree
   ```

### Acceptance criteria

- [ ] B-1 `esr actors list` count after step 2: 1 app-proxy + 9 thread-scope actors (3 × {thread, tmux, cc}) = 10
- [ ] B-2 Actors spawned in step 2 respect `depends_on`: `thread:t1` is alive before `tmux:t1` starts; `tmux:t1` is alive before `cc:t1` starts. Verify via `esr trace --last 1m --event esr.actor.spawned`.
- [ ] B-3 After step 3 (CLI-triggered `/new-thread t4`): `esr actors list` shows 13 actors total (10 + 3 new).
- [ ] B-4 After step 4 (duplicate `/new-thread t4`): `esr actors list` still 13 actors (idempotent).
- [ ] B-5 `esr actors tree` shows 1 app-proxy root with 4 independent thread subtrees; no cross-edges.
- [ ] B-6 Handler emits `InvokeCommand` (not `Spawn`, which is not in v0.1's action palette — see spec §4.4). Verified via `esr trace` payloads.

### Failure modes

| Symptom | Likely cause |
|---|---|
| `depends_on` violated (tmux spawned before thread) | Topology instantiator ignoring DAG order; see `runtime/lib/esr/topology/instantiator.ex` |
| Duplicate spawn on repeat `/new-thread t4` | Handler's `bound_threads` state not updated, OR `InvokeCommand` idempotency not implemented in runtime |
| `/new-thread` doesn't trigger anything | `feishu_app.on_msg` not parsing the slash-command; check `_NEW_THREAD_PREFIX` constant |

---

## Track C — Bidirectional Flow

**Goal:** verify a user message in Feishu reaches the CC tmux session, and CC output returns to the same Feishu thread.

### Preconditions

- Tracks A + B passed
- `e2e-cc.sh` exists: a trivial script the cc_tmux adapter will launch; it reads stdin and echoes back lines prefixed with `CC:`. Simulates CC without calling Anthropic.
- An actor graph bound to thread `t1`: `feishu-app:cli_TEST → thread:t1 → tmux:t1 → cc:t1` (spawned in Track B step 2).

### Scenario

1. **Feishu → CC (forward path)**
   Inject a `msg_received` event representing a real user message:
   ```bash
   esr debug inject \
     --to feishu-app:cli_TEST \
     --event '{"event_type":"msg_received","args":{"content":"hello world","msg_id":"m-1","thread_id":"t1"}}'
   ```
   Expected flow:
   1. `feishu_app.on_msg` → sees bound thread `t1` → `Route(target="thread:t1", msg="hello world")`
   2. `feishu_thread.on_msg` → dedups, emits `Emit(adapter="feishu-shared", action="react", ...)` + `Emit(adapter="cc_tmux", action="send_keys", args={"session": "t1", "content": "hello world"})`
   3. `cc_tmux` adapter writes `hello world` to the tmux session

2. **CC → Feishu (reverse path)**
   The tmux session (running `e2e-cc.sh`) outputs `CC: hello world`. The `cc_tmux` adapter observes this and emits an `event` upstream:
   ```
   Event(source="esr://localhost/adapter/cc_tmux/t1", event_type="cc_output", args={"text": "CC: hello world", "session": "t1"})
   ```
   `cc_session.on_msg` handler routes it back up → `tmux_proxy.on_msg` forwards to thread → `feishu_thread.on_msg` emits `Emit(adapter="feishu-shared", action="send_message", args={"chat_id": ..., "content": "CC: hello world"})`.

3. **Verify round trip**
   Capture the trace: `esr trace --session t1 --last 30s`.

### Acceptance criteria

- [ ] C-1 Forward path: tmux session `t1` receives `hello world` within 500 ms of the injected event (verified by `tmux capture-pane -t t1`).
- [ ] C-2 Reverse path: a `feishu` directive `send_message` was issued with `content="CC: hello world"` within 500 ms of the tmux output (verified by observing the feishu-shared adapter directive log; no real Feishu API call needed if a mock directive sink is configured for the E2E).
- [ ] C-3 Trace contains exactly this event sequence, in order: forward `msg_received → Route → send_keys`, reverse `cc_output → send_message`.
- [ ] C-4 Five round-trips (send 5 different messages, each with a distinct `msg_id`) all complete; messages arrive in FIFO order on both sides.
- [ ] C-5 End-to-end p95 latency across 5 round-trips < 500 ms (excluding external Feishu API which is stubbed).

### Failure modes

| Symptom | Likely cause |
|---|---|
| Forward path stops at `thread:t1` | Dedup bug in `feishu_thread.on_msg` (might mistakenly dedup the first message); or `tmux_proxy.on_msg` not linking to `cc_tmux` adapter |
| Reverse path stops at `cc:t1` | `cc_session.on_msg` not emitting a `Route` back upstream |
| Out-of-order delivery | Per-actor in-order dispatch broken; see §7.4 guarantee |

---

## Track D — Session Isolation

**Goal:** verify that messages to session A are invisible to sessions B/C, and that killing/crashing one session does not ripple.

### Preconditions

- Tracks A–C passed
- Three thread sessions active: `t1`, `t2`, `t3` (from Track B)

### Scenario

1. **Directed message to `t1`**
   Inject a `msg_received` event with `thread_id="t1"`. Observe: only `cc:t1`'s tmux receives the content; `cc:t2` and `cc:t3` tmux sessions remain silent.

2. **Kill `cc:t2`**
   ```bash
   esr cmd stop feishu-thread-session --param thread_id=t2
   ```
   Expected: `thread:t2`, `tmux:t2`, `cc:t2` stopped in reverse depends_on order (cc → tmux → thread).

3. **Verify t1 and t3 still work**
   Inject messages to each; both should still complete a forward round-trip.

4. **Inject an invalid event into `cc:t1`** (to test violation isolation)
   Inject an event that the handler would reject (e.g. an action outside its declared set). Expected: `[:esr, :handler, :violation]` fires with actor id `cc:t1`; the violation does not appear in `t2` or `t3`'s traces.

### Acceptance criteria

- [ ] D-1 Step 1: `tmux capture-pane -t t2` and `-t t3` show no content from the `t1` event.
- [ ] D-2 Step 2: only 3 actors stopped (`cc:t2`, `tmux:t2`, `thread:t2`); `esr actors list` count drops from 13 to 10.
- [ ] D-3 Step 3: forward round-trip on `t1` and `t3` still completes within 500 ms.
- [ ] D-4 Step 4: `esr trace --session t1 --filter violation` has one entry; `esr trace --session t2 --filter violation` and `--session t3 --filter violation` are empty.

### Failure modes

| Symptom | Likely cause |
|---|---|
| Message to `t1` leaks to `t2` | PubSub topic scoping broken — handler mistakenly publishing to a global topic |
| `cc:t2` stop takes `t1` or `t3` down | Supervisor strategy is `:one_for_all` where it should be `:one_for_one` |

---

## Track E — Observability

**Goal:** verify `esr trace`, `esr telemetry subscribe`, `esr actor inspect`, and `esr actor logs --follow` each produce the expected output.

### Preconditions

- Tracks A–D passed
- A stream of events is about to be generated (inject ~20 events across t1 and t3 in step 2 below)

### Scenario

1. **Subscribe to live telemetry in a separate shell**
   ```bash
   esr telemetry subscribe "esr.*" > /tmp/esr-telemetry.log &
   TEL_PID=$!
   ```

2. **Generate activity**
   Inject 20 `msg_received` events alternating between `t1` and `t3`, with 100 ms gaps.

3. **Query trace**
   ```bash
   esr trace --session t1 --last 5m > /tmp/esr-trace-t1.json
   ```

4. **Inspect a live actor's state**
   ```bash
   esr actor inspect cc:t1 > /tmp/esr-inspect-t1.json
   ```

5. **Tail an actor's logs**
   ```bash
   esr actor logs cc:t1 --follow > /tmp/esr-logs-t1.log &
   LOG_PID=$!
   # ... 3 seconds later ...
   kill $LOG_PID $TEL_PID
   ```

### Acceptance criteria

- [ ] E-1 `/tmp/esr-telemetry.log` contains ≥ 60 lines (step 2 emits 20 events × multiple telemetry hops); each line is valid JSON with `event` (list of atoms), `measurements`, `metadata` fields.
- [ ] E-2 `/tmp/esr-trace-t1.json` is a causally-ordered array of events with each event's `caused_by` pointing to a prior `id` in the same array (first event has `caused_by: null`).
- [ ] E-3 `/tmp/esr-inspect-t1.json` shows the `cc:t1` actor's full state: actor_id, actor_type, handler_module, state (pydantic-serialised), metadata, uptime.
- [ ] E-4 `/tmp/esr-logs-t1.log` contains scoped log lines (all from `cc:t1`, none from other actors); tails in real time (no > 1 s lag).
- [ ] E-5 A trace query for a non-existent actor returns `[]` with no error (not a crash).

### Failure modes

| Symptom | Likely cause |
|---|---|
| `esr trace` empty | Telemetry buffer not populated; check `Esr.Telemetry.Buffer` start-up or `:telemetry.attach/4` for CLI's query topic |
| `esr actor inspect` times out | CLI is asking for data from a different instance — confirm `esr use` context |
| Logs line-order wrong | PubSub ordering issue or timestamp not monotonic |

---

## Track F — Operations

**Goal:** verify `esr cmd stop` cascades cleanly, `esr drain` graceful-stops everything, and `esr restart` preserves state.

### Preconditions

- Tracks A–E passed
- At least two thread sessions active (`t1`, `t3`)

### Scenario

1. **Stop single session**
   ```bash
   esr cmd stop feishu-thread-session --param thread_id=t1
   ```
   Observe: reverse-depends_on cascade (cc → tmux → thread), ≤ 2 s.

2. **Drain all**
   ```bash
   esr drain --timeout 10s
   ```
   Observe: all actors enter `:draining`; no new events accepted; in-flight events complete or time out.

3. **Restart a specific command**
   ```bash
   # After drain, rebuild t1
   esr cmd run feishu-thread-session --param thread_id=t1
   # then stop and restart it
   esr cmd restart feishu-thread-session --param thread_id=t1
   ```
   Observe: thread's handler state is preserved across restart (e.g. `bound_threads` in feishu_app).

### Acceptance criteria

- [ ] F-1 Step 1: cascade order verified via trace — `cc:t1` stopped before `tmux:t1`, `tmux:t1` stopped before `thread:t1`.
- [ ] F-2 Step 2: within 10 s, `esr actors list` is empty; telemetry shows `[:esr, :drain, :complete]`.
- [ ] F-3 Step 3: after restart, `esr actor inspect feishu-app:cli_TEST` shows `bound_threads` unchanged (proves Elixir-side state survives a Python-side restart).
- [ ] F-4 Attempting `esr cmd stop` on a non-running command returns a clear error, not a silent no-op.

### Failure modes

| Symptom | Likely cause |
|---|---|
| Cascade order wrong | `Esr.Topology.Instantiator`'s stop reverses the wrong relation; should be reverse of spawn order |
| `drain` hangs | A PeerServer mailbox has stuck messages; timeout escalation missing |
| State lost on restart | `Esr.Persistence.Ets` not actually persisting across restart; or the "restart" unbinds state with `DynamicSupervisor.terminate_child` without preserving via checkpoint |

---

## Track G — Debug

**Goal:** verify `esr debug replay`, `esr debug inject`, `esr debug pause/resume`, and BEAM OTP restart under `kill -9`.

### Preconditions

- Tracks A–F passed
- A fresh set of actors spawned: `feishu-app:cli_TEST`, `thread:tg`, `tmux:tg`, `cc:tg`
- Telemetry captured from the last minute of activity

### Scenario

1. **Replay a message**
   Pick a `message_id` from the recent trace. Replay it:
   ```bash
   esr debug replay <message_id>
   ```
   Expected: the same event is re-injected to the same target actor; handler runs; telemetry fires again; the observable effect is repeated (e.g. a duplicate directive to the adapter). Dedup handled by the handler's state if the handler is idempotent on `msg_id`; this track does not assert idempotency — it asserts the mechanism works.

2. **Inject a synthetic test message**
   ```bash
   esr debug inject \
     --to cc:tg \
     --event '{"event_type":"cc_output","args":{"text":"from-debug","session":"tg"}}'
   ```
   Verify: the reverse path runs (cc → tmux → thread → feishu adapter).

3. **Pause / resume an actor**
   ```bash
   esr debug pause cc:tg
   esr debug inject --to cc:tg --event '{"event_type":"cc_output","args":{"text":"while-paused","session":"tg"}}'
   sleep 1
   # actor should not have processed the event yet
   esr debug resume cc:tg
   ```
   After resume, the event is processed (order-preserving).

4. **Kill the BEAM**
   ```bash
   PID=$(pgrep -f "beam.smp.*esrd-dev")
   kill -9 $PID
   ```
   Wait for launchd / mix release supervisor to restart the BEAM. Within 5 s, `esr status` should be responsive again; the `feishu-app:cli_TEST` actor should re-appear after ETS-checkpoint reload.

### Acceptance criteria

- [ ] G-1 Step 1 replay produces a new telemetry event with `caused_by=<original>` and `replay=true` metadata.
- [ ] G-2 Step 2 synthetic inject completes the reverse path — telemetry shows `from-debug` message traversing cc → tmux → thread → feishu-shared directive.
- [ ] G-3 Step 3 pause blocks processing; resume flushes queued events in FIFO.
- [ ] G-4 Step 4 recovery: `esr status` responsive within 5 s of kill; actor list re-populated from checkpoint; a `msg_received` injection after recovery completes a forward path.

### Failure modes

| Symptom | Likely cause |
|---|---|
| Replay doesn't fire the handler | Message history not persisted or `esr debug replay` not re-pushing to AdapterHub |
| Pause doesn't block | PeerServer's `handle_info` not honoring a `:paused` flag |
| BEAM doesn't restart | No supervisor or systemd/launchd unit; or Mix release not built as a release |

---

## Track H — Correctness & Consistency

**Goal:** verify system invariants hold over the E2E run.

### Preconditions

- Tracks A–G all passed; system is in the post-G state

### Scenario

Snapshot-only track — no new activity. Query the system against invariants:

1. **Trace vs topology**
   For each active session, verify `esr trace --session <id>` shows edges that are a subset of the edges declared in `patterns/.compiled/feishu-thread-session.yaml`.

2. **Handler action set**
   Scan the telemetry buffer for `[:esr, :handler, :called]` events; check every `actions` list contains only entries declared in that handler's allowed action set (v0.1: `emit`, `route`, `invoke_command`).

3. **Dead letter**
   ```bash
   esr deadletter list
   ```

4. **Source vs compiled artifact**
   ```bash
   esr cmd show feishu-thread-session --form py     # compile from .py
   esr cmd show feishu-thread-session --form yaml   # read .compiled/*.yaml
   # Instantiate both with the same params; diff the resulting spawn lists
   ```

### Acceptance criteria

- [ ] H-1 Step 1: no "unexpected" edges in any trace — every edge matches a declared one in the compiled topology.
- [ ] H-2 Step 2: no action of type other than `emit` / `route` / `invoke_command` appeared during the whole run.
- [ ] H-3 Step 3: `esr deadletter list` empty.
- [ ] H-4 Step 4: source-form and yaml-form produce identical spawn lists (same actor IDs, same handler/adapter bindings, same depends_on edges, same routing edges).

### Failure modes

| Symptom | Likely cause |
|---|---|
| Unexpected edge in trace | Handler emitted a Route to an actor not in the topology (handler bug or out-of-declared-set action slipped through runtime validation) |
| Unknown action type in telemetry | `Esr.Runtime`'s action validator missed one; spec §4.4 listed exactly the three allowed |
| Dead letters present | Events arrived for a non-existent actor, or handler retries exhausted (§7.3) |
| Source vs yaml differ | Compiler is not deterministic — introduces non-deterministic ordering or the EDSL interpreter picks up some env-dependent state |

---

## 9. Aggregate Success Gate

A v0.1 E2E "pass" requires:

- [ ] Every acceptance checkbox in Tracks A–H ticked
- [ ] 100 messages across 3 concurrent sessions (repeat C-4 with N=100 instead of 5): no loss, no duplicate, FIFO preserved per session
- [ ] Registration latency < 100 ms
- [ ] Message end-to-end p95 < 500 ms (Track C)
- [ ] BEAM `kill -9` recovery to messageable state ≤ 5 s (Track G)
- [ ] `esr trace` produces a full causal chain for each session (Track E)
- [ ] Handlers emit only declared actions (Track H-2)
- [ ] `esr deadletter list` empty throughout (Track H-3)

Any unticked box blocks v0.1 merge to `main`.

## 10. Non-goals (for v0.1 E2E)

These are **not** exercised by this document; they belong to v0.2:

- Multi-node BEAM cluster behaviour (libcluster, Horde)
- Webhook-receiving adapters (the HTTPS POST case)
- Full ESR contract YAML with static verification
- `esr install` Socialware bundles
- Cross-organisation exposure (`esr expose`)
- Handler hot-reload with state preservation during a code swap (v0.1 uses drain + restart)
- Socialware packaging round-trip

---

*End of E2E Platform Validation Specification v0.1.*
