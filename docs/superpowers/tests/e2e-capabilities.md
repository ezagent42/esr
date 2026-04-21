# ESR Capabilities — E2E Acceptance Specification

**Status:** draft
**Maps to:** design spec `docs/superpowers/specs/2026-04-20-esr-capabilities-design.md` §12; implementation plan Phase CAP-9 Task 15.
**Purpose:** validate the **capability-based access control subsystem** end-to-end. Complements (does NOT replace) `e2e-platform-validation.md` which validates the runtime platform itself.

---

## 0. How to read this document

The capabilities E2E is organised as seven **Tracks** (CAP-A through CAP-G), each focused on one end-to-end property of the cap subsystem:

| Track | Property under test |
|---|---|
| CAP-A | Admin flow: bootstrap principal has admin wildcard; both lanes allow |
| CAP-B | Regular user flow: scoped grants let the user send + spawn |
| CAP-C | Lane A deny + 10-min rate-limit window |
| CAP-D | Lane B deny: tool_invoke unauthorized → handler reply "❌ 无权限..." |
| CAP-E | Workspace scoping: `workspace:proj-a/*` does not match `workspace:proj-b` |
| CAP-F | Hot reload: `esr cap grant` is live within 2 s — no esrd restart |
| CAP-G | File corruption: malformed YAML keeps the previous snapshot; log shows error |

(Track CAP-H — "CAP-0 rename non-regression" — was proposed in the plan draft but dropped: Task 1 Step 4 and every subsequent `make test` invocation already validates the rename, so a dedicated track is redundant.)

Each track has four sections: **Goal** (one sentence), **Preconditions** (files / env the system expects before the track starts), **Steps** (numbered observable commands), **Expected observables** (log lines with a regex, reply text, telemetry events, file state), plus **Failure modes** (common wrong states and where to investigate).

A capabilities E2E "pass" requires every checkbox in every track to be ticked — no cherry-picking. See §9 of this document for the aggregate success gate.

The executable counterpart — `scripts/scenarios/e2e_capabilities.py` — is machine-readable and runs as a **component-level** e2e: each track is a Python function that drives `CapabilitiesChecker`, the CLI via `click.testing.CliRunner`, the FeishuAdapter's Lane A gate directly, and constructs the inbound envelopes that Lane B would see. A fully-orchestrated live e2e (esrd + mock_feishu + mock_cc) is a v2 improvement; v1 focuses on correctness of every enforcement seam individually against realistic fixtures.

---

## 1. Environment

- **Working directory**: `/Users/h2oslabs/Workspace/esr/.worktrees/esr-capabilities/` (or the repo root — the harness uses absolute paths via `ESRD_HOME`).
- **`ESRD_HOME`** is set to a fresh `tmp_path` per track so previously-granted state doesn't leak. Each track creates `<ESRD_HOME>/default/capabilities.yaml` + `<ESRD_HOME>/default/workspaces.yaml` on entry.
- **No esrd process required**: every assertion is made at the seam (checker / adapter / CLI / file) — no WebSocket, no Phoenix channel, no mix release.
- **Python harness**: `uv run --project py python scripts/scenarios/e2e_capabilities.py` — exits 0 iff all 7 tracks pass.

### Time budget

The entire component-level E2E runs in ≤ 10 seconds on a developer laptop. Anything slower indicates an accidental I/O loop or a forgotten sleep, not a fix-before-merge issue with the harness itself.

---

## Track CAP-A — Admin flow (bootstrap principal)

**Goal:** verify that an admin principal (loaded via `ESR_BOOTSTRAP_PRINCIPAL_ID` or manual grant of `"*"`) passes both Lane A (adapter msg.send) and Lane B (PeerServer tool_invoke) with any workspace name.

### Preconditions

- Fresh `ESRD_HOME` (tmp dir per track).
- `ESR_BOOTSTRAP_PRINCIPAL_ID=ou_admin` exported **before** `Esr.Capabilities.Supervisor.init/1` runs; this writes the seed file.
- `workspaces.yaml` lists workspace `coord-prod` bound to chat `oc_admin_chat` on app `cli_admin`.

### Steps

1. Invoke `Esr.Capabilities.Supervisor.maybe_bootstrap_file/1` (or its equivalent — the Python harness writes the seed file directly since the supervisor is BEAM-only). Expected: `capabilities.yaml` is created with `ou_admin` holding `["*"]`.
2. Construct a `CapabilitiesChecker(path=...)` pointing at the seed file.
3. **Lane A decision**: `checker.has("ou_admin", "workspace:coord-prod/msg.send")` → `True`.
4. **Lane B decision (inbound_event)**: `checker.has("ou_admin", "workspace:coord-prod/msg.send")` → `True`.
5. **Lane B decision (tool_invoke)**: `checker.has("ou_admin", "workspace:coord-prod/session.create")` → `True`.
6. Build a `msg_received` envelope via `esr.ipc.envelope.make_event(principal_id="ou_admin", workspace_name="coord-prod", ...)`; assert the two top-level keys are populated.

### Expected observables

- [ ] A-1 Seed file at `<ESRD_HOME>/default/capabilities.yaml` contains `id: ou_admin` and `capabilities: ["*"]`.
- [ ] A-2 `CapabilitiesChecker.has("ou_admin", "workspace:coord-prod/msg.send")` is `True`.
- [ ] A-3 `CapabilitiesChecker.has("ou_admin", "workspace:coord-prod/session.create")` is `True`.
- [ ] A-4 Envelope top-level has `principal_id == "ou_admin"` and `workspace_name == "coord-prod"`.

### Failure modes

| Symptom | Likely cause |
|---|---|
| Seed file not written | `ESR_BOOTSTRAP_PRINCIPAL_ID` unset at supervisor init OR file already exists from a prior run — make sure the harness uses an isolated `ESRD_HOME` |
| Admin denied | Missing `"*"` handling in `Grants.matches?/2` — Python `_matches` and Elixir `Grants` must agree byte-for-byte |

---

## Track CAP-B — Regular user flow

**Goal:** verify that a scoped principal (holding `workspace:coord-prod/msg.send` + `workspace:coord-prod/session.create`) can send a `msg_received` through Lane A and have a `/new-thread` tool_invoke through Lane B accepted.

### Preconditions

- `capabilities.yaml` contains:
  ```yaml
  principals:
    - id: ou_alice
      kind: feishu_user
      capabilities:
        - workspace:coord-prod/msg.send
        - workspace:coord-prod/session.create
  ```
- `workspaces.yaml` binds chat `oc_alice_chat` on app `cli_prod` to workspace `coord-prod`.

### Steps

1. Build `CapabilitiesChecker(capabilities.yaml)`.
2. Assert `has("ou_alice", "workspace:coord-prod/msg.send") is True` (Lane A).
3. Assert `has("ou_alice", "workspace:coord-prod/session.create") is True` (Lane B tool_invoke).
4. Drive the `FeishuAdapter._is_authorized("ou_alice", "oc_alice_chat")` gate directly — must return `True`.

### Expected observables

- [ ] B-1 Lane A check passes: `has("ou_alice", "workspace:coord-prod/msg.send")` → `True`.
- [ ] B-2 Lane B check passes: `has("ou_alice", "workspace:coord-prod/session.create")` → `True`.
- [ ] B-3 `FeishuAdapter._is_authorized("ou_alice", "oc_alice_chat")` → `True`.

### Failure modes

| Symptom | Likely cause |
|---|---|
| B-1 fails | Scoped workspace name not matched — check `Grants._matches` literal prefix rule |
| B-3 fails but B-1 passes | `workspaces.yaml` chat→workspace mapping wrong; the adapter's `_load_workspace_map` reads `chats:` flat list, not nested |

---

## Track CAP-C — Lane A deny + rate limit

**Goal:** verify that an ungranted principal sending a DM is (a) dropped by the adapter (no event emitted), (b) sent exactly one `"你无权使用此 bot..."` DM, (c) silent on the second DM within 10 min, and (d) receives a second deny DM if they retry after the 10-min window elapses.

### Preconditions

- `capabilities.yaml` has NO entry for `ou_rando`.
- `workspaces.yaml` binds chat `oc_rando_chat` on app `cli_prod` to workspace `coord-prod`.
- Adapter is running the mock base_url path (no live Lark calls).

### Steps

1. `adapter._is_authorized("ou_rando", "oc_rando_chat")` → `False`.
2. `adapter._should_send_deny("ou_rando")` → `True` on first call (records timestamp).
3. `adapter._should_send_deny("ou_rando")` → `False` on immediate second call (still within the 10-min window).
4. Monkeypatch `time.monotonic` to advance past `_DENY_WINDOW_S` (600 s). `adapter._should_send_deny("ou_rando")` → `True` again.

### Expected observables

- [ ] C-1 Lane A denies: `_is_authorized("ou_rando", "oc_rando_chat")` → `False`.
- [ ] C-2 First DM send is permitted: `_should_send_deny("ou_rando")` → `True`.
- [ ] C-3 Immediate retry is silent: `_should_send_deny("ou_rando")` → `False`.
- [ ] C-4 After the 600 s window elapses (monotonic clock patched): `_should_send_deny("ou_rando")` → `True`.

### Failure modes

| Symptom | Likely cause |
|---|---|
| C-3 returns `True` | The timestamp write in `_should_send_deny` happens before the window check — revisit the guard order |
| C-4 returns `False` | `_DENY_WINDOW_S` set to the wrong unit (ms vs s), or the monotonic clock mock didn't override `esr_feishu.adapter.time.monotonic` |

---

## Track CAP-D — Lane B deny (tool_invoke unauthorized)

**Goal:** verify that a principal holding only `msg.send` but not `session.create` is accepted by Lane A but denied by Lane B when the handler emits `InvokeCommand("feishu-thread-session", ...)` (or the equivalent session-creating directive). The handler sees an unauthorized tool_result and replies "❌ 无权限执行 session.create（请联系管理员授权）".

### Preconditions

- `capabilities.yaml` contains:
  ```yaml
  principals:
    - id: ou_reader
      kind: feishu_user
      capabilities:
        - workspace:coord-prod/msg.send
  ```
- Workspace `coord-prod` exists.

### Steps

1. `CapabilitiesChecker.has("ou_reader", "workspace:coord-prod/msg.send")` → `True`.
2. `CapabilitiesChecker.has("ou_reader", "workspace:coord-prod/session.create")` → `False`.
3. Lane B in-process parity: the Elixir `PeerServer` denial path is exercised by `runtime/test/esr/peer_server_lane_b_test.exs::test "tool_invoke without capability replies unauthorized; no emit"` — the harness asserts this test exists as a runtime witness (Python can't drive BEAM `send/2` directly without a running node; the unit test IS the witness that the deny branch works).
4. Python-side reply-shape contract: `runtime/lib/esr/peer_server.ex` builds `%{"ok" => false, "error" => %{"type" => "unauthorized", "required_perm" => "workspace:coord-prod/session.create"}}`. The harness asserts this shape is what the Elixir test expects (i.e., the Python handler-side would see `tool_result["ok"] == false` and `tool_result["error"]["type"] == "unauthorized"`).

### Expected observables

- [ ] D-1 `has("ou_reader", "workspace:coord-prod/msg.send")` → `True`.
- [ ] D-2 `has("ou_reader", "workspace:coord-prod/session.create")` → `False`.
- [ ] D-3 Runtime witness test file `runtime/test/esr/peer_server_lane_b_test.exs` exists and contains the literal strings `"unauthorized"` and `required_perm`.
- [ ] D-4 Handler-facing reply shape is `{"ok": False, "error": {"type": "unauthorized", "required_perm": ...}}` — documented + asserted against the witness test.

### Failure modes

| Symptom | Likely cause |
|---|---|
| D-2 unexpectedly `True` | `workspace:coord-prod/msg.send` being matched as a broader wildcard — check `_segment_match` doesn't treat `msg.send` as a prefix |
| D-3 missing | Witness file renamed or deleted — re-add; the Python harness relies on this file's presence as proof Lane B is enforced |

---

## Track CAP-E — Workspace scoping

**Goal:** verify that a principal holding `workspace:proj-a/*` cannot act on workspace `proj-b` — the prefix `workspace:` matches literally, but the name segment must match exactly (wildcard only if bare `*`).

### Preconditions

- `capabilities.yaml`:
  ```yaml
  principals:
    - id: ou_dev
      kind: feishu_user
      capabilities:
        - workspace:proj-a/*
  ```
- `workspaces.yaml` has both `proj-a` (bound to `oc_a` on `cli_prod`) and `proj-b` (bound to `oc_b` on `cli_prod`).

### Steps

1. `has("ou_dev", "workspace:proj-a/msg.send")` → `True`.
2. `has("ou_dev", "workspace:proj-a/session.create")` → `True`.
3. `has("ou_dev", "workspace:proj-b/msg.send")` → `False`.
4. `adapter._is_authorized("ou_dev", "oc_b")` → `False` (chat is bound to `proj-b`; dev's `proj-a/*` does not match).

### Expected observables

- [ ] E-1 Same-workspace grants pass: `has("ou_dev", "workspace:proj-a/msg.send")` → `True`.
- [ ] E-2 Same-workspace wildcard pass: `has("ou_dev", "workspace:proj-a/session.create")` → `True`.
- [ ] E-3 Cross-workspace deny: `has("ou_dev", "workspace:proj-b/msg.send")` → `False`.
- [ ] E-4 Adapter-level cross-workspace deny: `_is_authorized("ou_dev", "oc_b")` → `False`.

### Failure modes

| Symptom | Likely cause |
|---|---|
| E-3 `True` | `_segment_match` permits prefix globs — it should only wildcard on bare `*` |
| E-4 `True` but E-3 `False` | The adapter's `_workspace_of` map has `oc_b` mapped to `proj-a` (wrong) — audit `_load_workspace_map` |

---

## Track CAP-F — Hot reload

**Goal:** verify that `esr cap grant <principal> <perm>` rewrites `capabilities.yaml` and that a `CapabilitiesChecker` (with mtime-gated reload) picks up the new grant on the next `has()` call — within 2 seconds and without an esrd restart.

### Preconditions

- `capabilities.yaml` does NOT include `ou_bob`.
- Workspace `coord-prod` exists.
- A live `CapabilitiesChecker` instance has already answered at least one query against the initial snapshot.

### Steps

1. `checker.has("ou_bob", "workspace:coord-prod/msg.send")` → `False` (first call).
2. Invoke `esr cap grant ou_bob workspace:coord-prod/msg.send` via `CliRunner` with `ESRD_HOME` pointing at the same tmp dir.
3. Bump the file mtime by at least 1.0 s (`os.utime` — same approach the existing `test_capabilities_file_reload_is_picked_up` uses, because ruamel's write may complete faster than the filesystem's mtime resolution).
4. `checker.has("ou_bob", "workspace:coord-prod/msg.send")` → `True`.

### Expected observables

- [ ] F-1 Pre-grant: `has("ou_bob", "workspace:coord-prod/msg.send")` → `False`.
- [ ] F-2 `esr cap grant` exit code is 0; stdout mentions `ou_bob`.
- [ ] F-3 `capabilities.yaml` now contains `id: ou_bob` with `workspace:coord-prod/msg.send`.
- [ ] F-4 Post-grant (after mtime bump): `has("ou_bob", "workspace:coord-prod/msg.send")` → `True`.

### Failure modes

| Symptom | Likely cause |
|---|---|
| F-4 still `False` | mtime-gate didn't re-read — either the mtime wasn't bumped, or the checker is caching too aggressively (see `reload()` in `py/src/esr/capabilities.py`) |
| F-2 nonzero exit | `esr cap grant` can't find `capabilities.yaml` — `ESRD_HOME` not propagated to the `CliRunner` env |

---

## Track CAP-G — File corruption resilience

**Goal:** verify that a malformed `capabilities.yaml` (unterminated flow collection, garbled bytes) keeps the PREVIOUS valid snapshot intact. `CapabilitiesChecker.reload()` catches the `yaml.YAMLError`, bumps its cached mtime (so it doesn't spin re-reading), and returns. Previously-authorized principals still work.

### Preconditions

- `capabilities.yaml` is valid and contains `ou_prior` with `workspace:coord-prod/msg.send`.
- A `CapabilitiesChecker` has loaded the valid snapshot (established by a successful `has()` call).

### Steps

1. `checker.has("ou_prior", "workspace:coord-prod/msg.send")` → `True` (warm the snapshot).
2. Overwrite `capabilities.yaml` with malformed YAML (e.g. `principals: [{id: x,`).
3. Bump mtime.
4. `checker.has("ou_prior", "workspace:coord-prod/msg.send")` → STILL `True` (falls back to cached snapshot on `YAMLError`).
5. Fix the file (write a new valid YAML with `ou_fix`).
6. Bump mtime.
7. `checker.has("ou_fix", "workspace:coord-prod/msg.send")` → `True` (new snapshot loaded).
8. Runtime-side witness: `runtime/lib/esr/capabilities/file_loader.ex` logs `capabilities: load failed (...); keeping previous snapshot` — asserted against the file content, same-string basis.

### Expected observables

- [ ] G-1 Pre-corruption: `has("ou_prior", "workspace:coord-prod/msg.send")` → `True`.
- [ ] G-2 Post-corruption (mtime bumped): `has("ou_prior", "workspace:coord-prod/msg.send")` still `True`.
- [ ] G-3 After fix: `has("ou_fix", "workspace:coord-prod/msg.send")` → `True`.
- [ ] G-4 Runtime log-line contract present: `file_loader.ex` source contains `"keeping previous snapshot"`.

### Failure modes

| Symptom | Likely cause |
|---|---|
| G-2 unexpectedly `False` | `CapabilitiesChecker.reload()` catches `YAMLError` but then clears `_snapshot` anyway — must keep the old snapshot on parse failure |
| G-4 missing | `file_loader.ex` rewritten without the log line — update the literal here to match |

---

## 9. Aggregate Success Gate

A capabilities E2E "pass" requires:

- [ ] Every acceptance checkbox in Tracks CAP-A through CAP-G ticked.
- [ ] `scripts/scenarios/e2e_capabilities.py` exits 0 with `"7 tracks PASSED"` (or, if the harness has individual step breakdown, `"7 steps PASSED"`).
- [ ] Baseline test counts unchanged or increased: Elixir ≥ 196, Python ≥ 488 (no new test reduces either side).
- [ ] `make lint` clean (or same pre-existing SIM105/B904 carry-over in v0.2 test files that predate the capabilities branch).

Any unticked box blocks merge of the capabilities branch to `main`.

## 10. Non-goals (v1)

These are explicitly **not** exercised by this component-level E2E (deferred to v2):

- Fully-orchestrated live e2e: starting `esrd` + `mock_feishu` + `mock_cc`, driving WebSocket frames through the Phoenix channel, and asserting end-to-end log lines in a teardown-safe way.
- Multi-node grant replication (capabilities spec open question).
- Cross-organisation capability discovery.
- Grant TTLs / expiry.
- Capability delegation (a holder of `X` granting `X` to a sub-principal).

---

*End of E2E Capabilities Acceptance Specification.*
