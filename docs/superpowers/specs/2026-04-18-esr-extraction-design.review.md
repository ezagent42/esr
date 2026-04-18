# Independent Code Review — ESR v0.1 Extraction Design

**Reviewer:** superpowers:code-reviewer subagent (independent read)
**Date:** 2026-04-18
**Target:** `docs/superpowers/specs/2026-04-18-esr-extraction-design.md` (post v0.1.1 + URI-host fix)

---

## Critical (must fix before implementation)

- **Layer-number mismatch between text and diagram** — §2.1 — The ASCII diagram labels the Elixir runtime as "LAYER 1" and Handler as "LAYER 2", but the flow arrow in the diagram has Layer 4 → Layer 3 → Layer 1 → Layer 2, and every other section refers to them as "§3. Layer 1 — Actor Runtime", "§4. Layer 2 — Handler". That ordering contradicts the §0 text ("four disciplined layers: an Actor Runtime … and three Python layers — Handler, Adapter, Command"), which reads as 1→2→3→4 top-to-bottom. Pick one numbering and propagate it; readers will trip over this.

- **`Update` action is contradictory** — §4.4 — The `Update` dataclass is kept "Explicit state update marker (rare — returning new State is default)" but §4.2 says "Emit side-effects exclusively via Action objects" and state is returned via tuple. Either `Update` is redundant (delete it) or it bypasses the purity model (then spec needs semantics: what does `Update(patch={...})` mean when you've already returned `new_state`?). Currently unimplementable as stated.

- **Purity Check 3 has false-positive risk** — §4.3 — "globals() restricted to a whitelist" will trip on any decorator-applied wrapper, typing runtime artefacts (pydantic validators, `typing.get_type_hints`), and module-level constants the handler author legitimately uses. If the rule is strict it fails real handlers; if lenient it stops catching anything. Spec needs to define the whitelist precisely or drop Check 3 and rely on Checks 1+2.

- **`depends_on` semantics are load-bearing but undefined** — §5.5 / §6.3 — The spec adds `depends_on` as "explicit lifecycle dependency" and uses it for cc-on-zellij. But there's no definition of what "dependency" means at runtime: does the parent's crash stop the child? Does the child wait for parent state before accepting events? How does `esr cmd stop` cascade? Critical because this is the user's answer to "no adapter nesting".

- **Handler worker state/concurrency model is missing** — §3.4 / §4 — Handlers are "stateless, pooled per module" and the runtime guarantees "per-actor in-order dispatch" (§7.4). But if Actor A's events are dispatched to any worker from the pool, state is passed in/out each call (pydantic ser/de on every event) — this makes the 3–20ms handler RPC in §9.3 tight but not unreasonable, and it's a big performance shift from cc-openclaw where handlers are in-process. Spec should state explicitly: "state travels with every call; pool is stateless" and call out the ser/de cost as the expected hot path, otherwise implementers will want to add worker affinity and break the model.

## Significant (should address)

- **ESR v0.3 §10.1 conformance gap** — §1.3 — v0.3 MUST requires `contract_declaration` and `static_verification`. v0.1 explicitly defers both (§1.2 "Full contract verifier infrastructure"; §11 "Explicit contract YAML"). Spec claims "partial-ESR-conforming" in §1 but v0.1 supplies *neither* MUST capability — that's non-conforming, not partial. Either rewrite as "pre-ESR / runtime-only skeleton" or add a minimal contract YAML + static validator in v0.1 scope.

- **`Route(target=...)` uses raw string but §7.5 says cross-boundary refs use `esr://`** — §4.1 example shows `Route(target=state.feishu_peer, msg=...)` where `state.feishu_peer` is declared `str | None` (§4.5). Action goes Python → IPC → Elixir — that's cross-boundary. The spec rule says it must be `esr://`. Either §4 examples should use full URIs or §7.5 needs an explicit carve-out for actor-id targets inside an instance.

- **Spawn action has both `id` and no URI** — §4.4 — `Spawn(actor_type=..., id=..., ...)` — same issue. If Spawn crosses IPC (it does), `id` should be a full URI or the spec needs to clarify that actor IDs within a single PeerServer org are resolved relative to that org. §7.5 currently says "All cross-boundary references … use the full esr:// form" without carve-outs.

- **"Topology is first-class; actors reconcile to match it" (§3.5) conflicts with handler-emitted Spawn/Stop** — Handlers can emit `Spawn` and `Stop` actions (§4.4), and §2.3 says "Spawn/Stop → PeerSupervisor reconciles topology". If the topology artifact is authoritative, what happens when a handler spawns an actor not in the topology? Is that an error? A runtime extension? If spawns are free-form, what does "reconcile to match topology" mean? Pick one.

- **Dogfooding §3.8 vs `esr://` rule** — §3.8 — Two-instance setup has prod on :4000, dev on :4001. A dev-instance debug log mentioning a prod actor must use `esr://localhost:4000/actor/...`. Spec doesn't address how the two instances discover each other's port or if they're meant to be mutually invisible. If fully isolated, say so; if "dev can inspect prod via URI", show the escape hatch.

- **`esr status` vs `esr actors list` vs `esr cmd list` bootstrap** — §3.7 / §9.2 Track A — `esr status` is declared as "org view", and Track A's acceptance test is that `esr adapter/handler/cmd list` "reflect expected state". But with no auth (§11 "CLI auth: No auth in v0.1"), which instance does `esr` talk to if you have `esrd-prod` and `esrd-dev` both running on the same box? `esr use <host:port>` is mentioned once but it's unclear whether that's persistent, per-shell, per-command. State the config storage for the CLI context (probably `~/.esr/context`).

- **Migration §10.1 ignores `sidecar/` business logic that blocks the daily channel** — `sidecar/` is ~2,000 LoC of Feishu provisioning, group reconciliation, permission, broadcasting, event handling. Spec says "unchanged in v0.1". But Track C requires "a message in Feishu chat reaches the bound tmux session" — in cc-openclaw today, Feishu events go through sidecar's `feishu_events.py` (permission checks, provisioning, chat→agent mapping) *before* reaching the actor runtime. If sidecar stays unchanged, either (a) esr/ has no Feishu inbound at all, or (b) esr/ duplicates the permission/provisioning logic in a new adapter. Spec needs to state: does esr v0.1 share the sidecar with cc-openclaw, replace it, or proxy through it? Currently the migration table is silent on how inbound events reach the Feishu adapter.

- **Sidecar HTTP + WebSocket + Feishu callbacks — IPC v0.1 can't serve all three** — §7 only specifies Phoenix Channels for adapter↔runtime and handler↔runtime. cc-openclaw's Feishu event callback is an HTTPS POST from Feishu → `channel_server/app.py` or sidecar. Where does that land in esr v0.1? The Feishu adapter would need an inbound HTTP listener, which is neither "WebSocket join" nor "emit_events async-gen". Spec should show the adapter-hosting model for webhook-receiving adapters.

- **Handler worker crash recovery undefined** — §3.4 shows `{:error, :handler_timeout}`. What about `{:EXIT, worker_pid, :segfault}`? Spec mentions "worker reconnects with exponential backoff" but says nothing about in-flight calls, replay vs drop, telemetry signal. This is a BEAM-Python boundary where a silent pool-eviction would lose a message. Add to §7.3.

- **State schema evolution undefined** — §4.5 stores state as frozen pydantic. When a handler adds a required field, every persisted ETS entry becomes invalid. Spec says "Runtime serialises state via pydantic for IPC and persistence" but not what happens when the Python code evolves. Add: v0.1 policy = "breaking state changes require drain + reset"; punt migration tooling to v0.2. At least declare it.

- **Topology schema doesn't include ESR v0.3 topology fields** — §6.3 YAML has `name/params/ports/nodes/edges` but ESR v0.3 §5.2 topologies require `description`, `trigger`, `participants` (with `role_in_this_topology`), `flows`, `acceptance_criteria`. §1.3 deferral "does not yet implement … topology validation" doesn't cover *schema shape*. If v0.1 invents a different topology YAML, v0.2 will face migration pain. Consider: name the v0.1 artifact "pattern-compiled" not "topology" to reserve that keyword for ESR v0.3 semantics.

- **`message_shape` absent from every example** — ESR v0.3 §8 requires payload envelope with `source`, `destination_indicator`, `payload`, `metadata`. §7.2 shows `{"id","ts","type","payload"}` — no `source` field at IPC level. PeerServer will need to inject it, but spec should show the final envelope shape that handlers observe.

- **`esr adapter install` vs "CI scan `allowed_io`" on untrusted source** — §5.2 / §5.6 — Install flow step 3 runs a "capability declaration check" but module import (step 2) executes code, and `@adapter(...)` registration is arbitrary Python. Malicious or buggy adapter code runs with full privileges at install time. Spec should state: v0.1 trusts adapter authors (same trust boundary as handlers); sandboxing is out of scope. Otherwise readers may assume `esr adapter install` is safe for untrusted URLs.

## Minor / Polish

- §2.2 table: "Layer" column is "Elixir" / "Python", not a layer number — rename to "Owner".

- §3.2 PeerServer state includes `handler_ref` (singular) but handlers are "one worker pool per module" — clarify whether the ref is the handler *module name* (most likely) or a specific worker PID.

- §3.7 "`esrd` Elixir escript … Transport: `:erl_call` or BEAM RPC (no Phoenix)" — `:erl_call` needs cookie; spec should mention cookie-file location to avoid reinventing it at implementation time.

- §3.8 "Per-instance configuration storage" shows `~/.esrd/<instance-name>/` for configs but §3.8 uses `esrd init --org-name` (no `--instance-name`). Show the full init command and how `esrd-prod` vs `esrd-dev` are named.

- §4.1 example: `on_msg` receives `event.msg_id` and `event.content` — these are ad-hoc attrs on `Event`, but §5.3 says `Event(source, event_type, args)`. Should be `event.args["msg_id"]`. Small but will confuse anyone reading this as a reference.

- §5.1 example: `@adapter(name="feishu", allowed_io={"lark_oapi": "*", "http": ["open.feishu.cn"]})` — how does CI detect that `LarkClient(...)` uses `lark_oapi`? This needs a doc statement like "imports are scanned; `allowed_io` keys are import-name prefixes".

- §5.4 `esr adapter add feishu --app-id ...` — `feishu` here is an *instance* name, but `feishu` is also the *installed module* name in §5.6. What if you install two adapters with `name="feishu"`? Spec needs a rule for instance-name uniqueness scope (probably: per installed-type).

- §6.1 "Names are project-scoped and must be unique; duplicates fail registration" — but §6.8 `esr cmd install` can pull from a Git URL. If the remote file defines `@command("feishu-to-cc")` and I already have one, install fails. State the conflict-resolution policy: error and abort, or namespace via source?

- §6.2 example — `core_actor` has no adapter in `core-to-cc`. Is an adapter-less actor legal? If yes (plausible — pure routing actor), §5 should say so; if no, the example is broken.

- §7.2 `directive_ack` envelope omits the `adapter` field but Elixir needs to route acks back. Either rely on Phoenix topic membership (fine, but say so) or add the field.

- §7.4 "Handler actions apply transactionally" — two-phase commit across ETS (state) and Phoenix Channels (action emission) is non-trivial. Likely what's meant is "persist state first, then emit; on persistence failure, drop actions; on emission failure, action is lost but state is kept". State the real guarantee; "transactional" overpromises.

- §7.5 Examples use `feishu-shared` and `zellij-5` as `<id>` in adapter URIs, but §7.1 topic is `adapter:<name>/<instance_id>`. So the URI id = instance_id. State that.

- §9.3 latency table — "Handler RPC round-trip 3–20ms" assumes a warm pool. Cold-start (worker spawn + module import + ser/de setup) is more like 500–2000ms. Add a "cold start" row or state pool warm-up is Phase-0 of `esr cmd run`.

- §10.1 row for `channel_server/commands/builtin/spawn.py` → `patterns/feishu-to-cc.py` — the cc-openclaw `spawn.py` is 102 lines of imperative spawn-and-link-actors code. Reimagining it as a declarative pattern is correct but non-trivial; spec should flag this as "Rewritten, not ported".

- §10.2 phasing list numbers 1–8 but has no dependencies or parallelisation — is this sequential? Would benefit from a mermaid DAG showing critical path (runtime → IPC → adapters; handlers can proceed in parallel once IPC is ready).

- §11 "Handler hot-reload … Deferred; restart is fine for v0.1" — conflicts with §3.8's "Dogfooding esrd while using esrd". If every restart drops Feishu connections (§3.8), developing handlers means restarting esrd-dev; that's fine but state it: "handler code change = `esr handler upgrade <name>` triggers graceful worker drain + restart; esrd stays up".

## Strengths worth preserving

- **The three-layer management surface (§3.7)** is a genuinely good separation — `esrd` for daemon ops, `esr` for inside-daemon ops, BEAM REPL for emergencies — and the explicit "two `status` commands answer different questions" is the kind of API-detail decision that prevents years of confusion.

- **§3.8 "One esrd = one org, can host many instances"** resolves the "second Feishu app = second org?" footgun clearly. The prod/dev two-instance dogfooding recipe is pragmatic and spec-worthy.

- **§5.2 capability-declaration over runtime sandboxing** is the right call for Python — sandboxing a process that imports arbitrary packages is a lost battle; narrowing the declared surface catches the common failure mode (handler author adds `requests` without thinking).

- **§5.5 "no adapter nesting, use topology instead"** with the cc-on-zellij worked example shows the user has already thought through the hard case and picked the composable answer.

- **§7.5 `esr://` URI with mandatory-host rule** is clean and extensible; the explicit `localhost` convention avoids the "default = local" ambiguity trap.

- **§9 E2E validates the platform, not a demo** — Tracks A–H covering registration, scheduling, observability, ops, debug, correctness is a significantly higher bar than "the message went through once", and catches the whole class of "it works in hello-world but falls over under multi-session load" problems.

- **§9.3 "latency is monitored, not optimised"** is a good YAGNI posture for v0.1 and the "instrument day one, profile only when threshold breached" rule is concrete enough to enforce.
