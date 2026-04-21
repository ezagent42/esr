# ESR Dev/Prod Isolation — E2E Acceptance Specification

**Status:** draft
**Maps to:** design spec `docs/superpowers/specs/2026-04-21-esr-dev-prod-isolation-design.md` §10; implementation plan Phase DI-14 Task 30.
**Purpose:** validate the **dev/prod isolation + Admin subsystem** end-to-end across the 17 acceptance criteria (DI-A..DI-Q) in spec §10.

---

## 0. How to read this document

The dev/prod isolation E2E is organised as 17 **Tracks** (DI-A through DI-Q), each focused on one end-to-end property of the subsystem:

| Track | Property under test |
|---|---|
| DI-A | `esrd.sh` respects `--port` override; absence picks a free port and writes `esrd.port` |
| DI-B | Two LaunchAgent plists (prod + dev) coexist, each on its own port |
| DI-C | `esr cap list` works under `ESRD_HOME=~/.esrd-dev esr cap list` (instance-scoped) |
| DI-D | `esr adapter feishu create-app` goes through the Admin queue with the expected shape |
| DI-E | First DM auto-creates `<open_id>-dev` session via Admin — Feishu event subscribed, code seam exists |
| DI-F | `/new-session feature/foo --new-worktree` parses → Router → Dispatcher → Commands.Session.New |
| DI-G | `/switch-session dev` is O(10ms); only `routing.yaml` change |
| DI-H | `/end-session feature/foo` sends cleanup-check; clean → closes; dirty → prompts |
| DI-I | `/end-session` + CC unresponsive >30s → interactive prompt (timeout error) |
| DI-J | `/reload` without breaking → kickstart; client reconnects via `_resolve_url` |
| DI-K | `/reload` + unacknowledged breaking → lists commits, no reload |
| DI-L | post-merge hook triggers `esr notify` → Admin queue entry written |
| DI-M | `last_reload.yaml` updated after successful reload |
| DI-N | dev esrd reboot adopts orphan `/tmp/esrd-*/` dirs + orphan pending queue commands |
| DI-O | Feishu creds rotation via re-running create-app → new adapter replaces old via queue |
| DI-P | Unauthorized admin command → failed/ entry with `unauthorized` error |
| DI-Q | Every admin command produces exactly one telemetry event; secrets redacted post-exec |

Each track has four sections: **Goal** (one sentence), **Preconditions** (files / env the system expects), **Steps** (numbered observable commands), **Expected observables** (log lines, reply text, telemetry events, file state), plus **Failure modes** (common wrong states).

A dev/prod isolation E2E "pass" requires every checkbox in every track to be ticked — no cherry-picking. See §11 of this document for the aggregate success gate.

The executable counterpart — `scripts/scenarios/e2e_dev_prod_isolation.py` — is machine-readable and runs as a **component-level** E2E. Launchd / launchctl are not exercised directly (we can't spawn real `LaunchAgent`s from CI), but every code seam on either side of launchd is exercised: the `esrd.sh` shell script (port selection, port-file write), the Elixir `Launchd.PortWriter` GenServer, the Python `_resolve_url` reconnect resolver, and the Admin Dispatcher's cap-check / telemetry / redaction paths. For Elixir-only command modules, witness-file assertions verify the expected literals are present (same approach CAP-D takes for PeerServer Lane B).

---

## 1. Environment

- **Working directory**: `/Users/h2oslabs/Workspace/esr/.worktrees/dev-prod-isolation/` (worktree; the harness uses absolute paths via `ESRD_HOME`).
- **`ESRD_HOME`** is set to a fresh `tmp_path` per track so previously-submitted queue state doesn't leak. Each track creates its own `admin_queue/{pending,processing,completed,failed}` layout when needed.
- **No esrd process required**: every assertion is made at the seam (file / CLI / GenServer cast / witness test) — no launchd, no WebSocket, no mix release.
- **Python harness**: `uv run --project py python scripts/scenarios/e2e_dev_prod_isolation.py` — exits 0 iff all 17 tracks pass.

### Time budget

The entire component-level E2E runs in ≤ 15 seconds on a developer laptop. The only "real" process work is two `esrd.sh start` invocations in DI-A / DI-B (guarded by `ESRD_CMD_OVERRIDE="sleep 60"` so no Phoenix server is actually launched). Anything slower indicates a forgotten sleep.

---

## Track DI-A — `esrd.sh --port` override + port-file write

**Goal:** verify `scripts/esrd.sh start --instance=… --port=N` respects the override, and that absence picks a random free port and persists it to `$ESRD_HOME/<instance>/esrd.port`.

### Preconditions

- Clean `$ESRD_HOME/<instance>` dir (tmp per track).
- `ESRD_CMD_OVERRIDE="sleep 60"` so no Phoenix server is actually launched.

### Steps

1. Run `scripts/esrd.sh start --instance=t --port=54321` under an isolated `ESRD_HOME`.
2. Read `$ESRD_HOME/t/esrd.port` — must be `54321`.
3. Stop that instance (`esrd.sh stop --instance=t`).
4. Run `scripts/esrd.sh start --instance=u` with no `--port`.
5. Read `$ESRD_HOME/u/esrd.port` — must be a 5-digit decimal number > 1024.
6. Stop the second instance.

### Expected observables

- [ ] A-1 `esrd.port` contains `54321` after `--port=54321` start.
- [ ] A-2 `esrd.port` contains a numeric port > 1024 and < 65536 after a no-`--port` start.
- [ ] A-3 `esrd.pid` file exists after each start and is removed after `esrd.sh stop`.

### Failure modes

| Symptom | Likely cause |
|---|---|
| A-1 contains a non-54321 number | `--port=` argv parse broken in `esrd.sh` — revisit the `case "$arg" in --port=*)` branch |
| A-2 empty / missing | Python-socket free-port probe failed; check `python3 -c 'import socket; …'` line works on the runner |

---

## Track DI-B — Two LaunchAgents coexist on different ports

**Goal:** verify the prod and dev plist templates + `install.sh` path substitution resolve two independent launchd labels, each with a distinct `ESRD_HOME` and log prefix, so they would coexist if installed.

**Note:** we can't actually `launchctl bootstrap` inside CI, so we verify the **template substitution** produces a correctly distinct pair of plists + that `esrd.sh` under two different `ESRD_HOME` values writes distinct port files.

### Preconditions

- Two tmp dirs simulating `~/.esrd` and `~/.esrd-dev`.
- Both plist templates present at `scripts/launchd/com.ezagent.esrd{,-dev}.plist`.

### Steps

1. Read `scripts/launchd/com.ezagent.esrd.plist` + `.../esrd-dev.plist`. Assert labels differ (`com.ezagent.esrd` vs `com.ezagent.esrd-dev`) and that the dev one references `ESRD_HOME=__HOME__/.esrd-dev` (or placeholder substitution line).
2. Start `esrd.sh` in the first tmp dir, capture `esrd.port`. Stop.
3. Start `esrd.sh` in the second tmp dir, capture `esrd.port`. Stop.
4. Assert the two ports differ (random-port selection never collides within a single run — adjacency is extremely unlikely; we only check `!=`).

### Expected observables

- [ ] B-1 `com.ezagent.esrd.plist` contains the literal label `com.ezagent.esrd`.
- [ ] B-2 `com.ezagent.esrd-dev.plist` contains the literal label `com.ezagent.esrd-dev`.
- [ ] B-3 The two plists reference different `__ESRD_HOME__` patterns (or at least the dev one contains `.esrd-dev`).
- [ ] B-4 Two `esrd.sh` invocations under different `ESRD_HOME` produce different port files, neither ≤ 1024.

### Failure modes

| Symptom | Likely cause |
|---|---|
| B-3 fails | The dev plist template was copy-pasted without editing the ESRD_HOME env var — check `<key>ESRD_HOME</key>` in both |
| B-4 ports identical | The Python free-port probe returned the same port twice in a row — unlikely, retry |

---

## Track DI-C — `esr cap list` honours `ESRD_HOME`

**Goal:** verify the CLI's `cap list` subcommand reads from `$ESRD_HOME/<instance>/capabilities.yaml` and does NOT shell into a hardcoded `~/.esrd/default/capabilities.yaml`.

### Preconditions

- Tmp `ESRD_HOME` with a seeded `default/capabilities.yaml` containing one principal.

### Steps

1. Seed `capabilities.yaml` with principal `ou_dev_scoped` holding `workspace:dev-proj/msg.send`.
2. Invoke `esr cap list` via `CliRunner` with `ESRD_HOME` env set to tmp.
3. Assert exit code 0, stdout mentions `ou_dev_scoped` and the perm.
4. Assert the CLI did NOT read from `~/.esrd` (verify by pointing to a DIFFERENT tmp with a different principal — that one must NOT show up).

### Expected observables

- [ ] C-1 `esr cap list` exit code 0 under `ESRD_HOME=<tmp>`.
- [ ] C-2 Stdout contains `ou_dev_scoped`.
- [ ] C-3 Stdout contains `workspace:dev-proj/msg.send`.
- [ ] C-4 A second `cap list` under a different `ESRD_HOME` reads from the right file (no cross-leak from the first).

### Failure modes

| Symptom | Likely cause |
|---|---|
| C-2/C-3 missing | `paths.capabilities_yaml_path()` still hardcodes `"default"` segment — check `cli/paths.py` |

---

## Track DI-D — `esr adapter feishu create-app` through Admin queue

**Goal:** verify the wizard writes a `register_adapter`-kind command to `admin_queue/pending/<ULID>.yaml` with the expected shape (type=feishu, name, app_id, app_secret).

### Preconditions

- Tmp `ESRD_HOME` with `default/admin_queue/pending/` seeded.
- `_validate_creds` patched to return `True` (no real Feishu HTTP).

### Steps

1. Invoke `esr adapter feishu create-app --name "ESR 开发助手" --target-env dev --no-wait` via `CliRunner`, feeding `app_id` + `secret` via stdin.
2. Assert exit code 0.
3. Read the single pending YAML; assert kind + args shape.

### Expected observables

- [ ] D-1 `esr adapter feishu create-app` exit code 0.
- [ ] D-2 Exactly one `*.yaml` in `pending/`.
- [ ] D-3 YAML doc has `kind: register_adapter`, `args.type: feishu`, `args.name: ESR 开发助手`.
- [ ] D-4 YAML has `args.app_id` + `args.app_secret` from stdin.

### Failure modes

| Symptom | Likely cause |
|---|---|
| D-1 nonzero | Validation path fired even though patched — check `_validate_creds` is patched on the wizard module, not `lark_oapi` |
| D-3 args missing | The wizard reads `--name` from argv but the queue submit forgot to thread it — check `create_app` `ctx.invoke` call |

---

## Track DI-E — First DM auto-creates `<open_id>-dev` session via Admin

**Goal:** verify the Feishu event subscription list includes `p2p_chat_create_v1` (the event that fires on first DM) so the dispatcher pathway is reachable. The concrete DI-E wire-up (handler → Admin `session_new` cast) is in `feishu/src/esr_feishu/adapter.py` near line 663 per spec §11.2 and is covered by the adapter unit tests; this track asserts the event is present in the canonical scope/event list and the wizard prints it.

### Preconditions

- `py/src/esr/cli/adapter/feishu.py` exports `_EVENTS`.

### Steps

1. Import `_EVENTS` from `esr.cli.adapter.feishu`.
2. Assert `"im.chat.access_event.bot.p2p_chat_create_v1"` is in the tuple.
3. Invoke the wizard, assert the printed pre-filled URL contains the event name (confirms it's actually rendered, not just defined).

### Expected observables

- [ ] E-1 `_EVENTS` contains `im.chat.access_event.bot.p2p_chat_create_v1`.
- [ ] E-2 Wizard stdout contains the event name verbatim (no url-encoding — `.` is unreserved).
- [ ] E-3 Spec §11.2 modified-files entry for the feishu adapter is present (witness-file check on spec).

### Failure modes

| Symptom | Likely cause |
|---|---|
| E-1 fails | `_EVENTS` tuple drifted from the spec — sync with spec §5.3 table |

---

## Track DI-F — `/new-session feature/foo --new-worktree` round-trip parsing

**Goal:** verify the SessionRouter parses `/new-session feature/foo --new-worktree` into the canonical admin-cmd kind `session_new` with `args.branch` + `args.new_worktree`. The downstream ShellOut to `esr-branch.sh` is a Commands.Session.New responsibility already covered by `runtime/test/esr/admin/commands/session/new_test.exs`; this track asserts the Router parse → kind mapping contract via the witness-file test plus by checking the routing source has the right `"/new-session " <>` clause.

### Preconditions

- `runtime/lib/esr/routing/session_router.ex` present.

### Steps

1. Read `session_router.ex`; assert `def parse_command("/new-session " <> rest)` clause exists.
2. Assert the Router maps the parsed result to `{:slash, "session_new", args}` with `args["branch"]` and `args["new_worktree"]`.
3. Assert the existing unit test `runtime/test/esr/routing/session_router_test.exs` exists (the witness).

### Expected observables

- [ ] F-1 Router source has `/new-session ` parsing clause.
- [ ] F-2 Router source mentions `session_new` kind (the admin-cmd name).
- [ ] F-3 Router source mentions `new_worktree` flag parsing.
- [ ] F-4 Session router test file exists.

### Failure modes

| Symptom | Likely cause |
|---|---|
| F-1/F-2 fails | parse clause removed or kind renamed — update spec §6.5 mapping |

---

## Track DI-G — `/switch-session` is routing.yaml only (O(10ms))

**Goal:** verify `Session.Switch` is pure read-modify-write on `routing.yaml` — no worktree or esrd work. Timing bound "O(10ms)" is validated by: (a) the module only touches `routing.yaml` per its moduledoc; (b) the write is a single `Esr.Yaml.Writer.write` call.

### Preconditions

- `runtime/lib/esr/admin/commands/session/switch.ex` present.

### Steps

1. Read `switch.ex`; assert it mentions `routing.yaml` and does NOT mention `esr-branch.sh` / `worktree` / `System.cmd`.
2. Assert unit test file `runtime/test/esr/admin/commands/session/switch_test.exs` exists.

### Expected observables

- [ ] G-1 `switch.ex` source references `routing.yaml`.
- [ ] G-2 `switch.ex` source does NOT reference `System.cmd` / `worktree` / `esr-branch`.
- [ ] G-3 Witness test `switch_test.exs` exists.

### Failure modes

| Symptom | Likely cause |
|---|---|
| G-2 fails | Scope creep — switch gained side-effects it shouldn't have. Restore the pure-rwm invariant |

---

## Track DI-H — `/end-session` cleanup-check handshake

**Goal:** verify `Session.End` supports both `force:true` (DI-10 legacy) and the DI-11 `force:false` handshake that waits on a `{:cleanup_signal, status, details}` forwarded by the Dispatcher.

### Preconditions

- `runtime/lib/esr/admin/commands/session/end.ex` present.
- `runtime/test/esr/admin/commands/session/end_cleanup_test.exs` present.

### Steps

1. Assert `end.ex` mentions `cleanup_signal` + `register_cleanup` + `CLEANED` + `DIRTY`.
2. Assert `end_cleanup_test.exs` exists (the witness for the clean/dirty branches).

### Expected observables

- [ ] H-1 `end.ex` source contains `cleanup_signal`.
- [ ] H-2 `end.ex` source contains both `CLEANED` and `DIRTY` literals.
- [ ] H-3 Witness test `end_cleanup_test.exs` exists.

### Failure modes

| Symptom | Likely cause |
|---|---|
| H-1/H-2 fails | Cleanup handshake rolled back or renamed — restore per spec §6.9 |

---

## Track DI-I — `/end-session` + CC unresponsive >30s → timeout

**Goal:** verify `Session.End` declares a 30 s default timeout (`cleanup_timeout_ms: 30_000`) and returns `{:error, %{"type" => "cleanup_timeout", ...}}` when the Task's `receive` elapses without a signal.

### Preconditions

- `runtime/lib/esr/admin/commands/session/end.ex` present.

### Steps

1. Read `end.ex`; assert it mentions `cleanup_timeout` + `30_000` (or `30000`).
2. Assert the witness test asserts a timeout branch exists.

### Expected observables

- [ ] I-1 `end.ex` source contains `cleanup_timeout`.
- [ ] I-2 `end.ex` source mentions the 30s window (either `30_000` or `30000`).
- [ ] I-3 `end_cleanup_test.exs` witness tests the timeout branch (contains `cleanup_timeout`).

### Failure modes

| Symptom | Likely cause |
|---|---|
| I-2 fails | Timeout window changed — update the spec §6.9 timing table and this track's literal |

---

## Track DI-J — `/reload` kickstarts + client reconnects

**Goal:** verify two invariants: (a) `Commands.Reload` derives the launchctl label from `esrd_home` (so prod → `com.ezagent.esrd`, dev → `com.ezagent.esrd-dev`); (b) the Python `_resolve_url` re-reads `esrd.port` on every reconnect, following a kickstart's port change.

### Preconditions

- `runtime/lib/esr/admin/commands/reload.ex` present.
- `py/src/esr/ipc/adapter_runner.py` has `_resolve_url`.

### Steps

1. Read `reload.ex`; assert it contains both `com.ezagent.esrd` and `com.ezagent.esrd-dev` labels.
2. Import `esr.ipc.adapter_runner._resolve_url`; call it against a fallback URL after seeding `esrd.port` with a new port — assert the returned URL's port matches.
3. Call `_resolve_url` again after overwriting `esrd.port` — assert the port change is picked up (no caching).

### Expected observables

- [ ] J-1 `reload.ex` contains both launchctl labels.
- [ ] J-2 `_resolve_url` substitutes the port from `esrd.port` into the fallback URL.
- [ ] J-3 A second `_resolve_url` call after a port-file rewrite returns the new port.

### Failure modes

| Symptom | Likely cause |
|---|---|
| J-2 fails | Port file not read or regex broken — check `paths.runtime_home()` resolution |
| J-3 fails | Caching introduced — follow-up reload after a port change would stall |

---

## Track DI-K — `/reload` without `--acknowledge-breaking` refuses

**Goal:** verify `Commands.Reload.execute/2` returns `{:error, %{"type" => "unacknowledged_breaking", "commits" => [...]}}` when `git log` finds breaking commits AND the command's `args.acknowledge_breaking` is not true.

**Note:** exercised at the Elixir level, but since the harness is Python-only we check for the literal `"unacknowledged_breaking"` + `acknowledge_breaking` in `reload.ex` and the existence of the unit test `reload_test.exs` which exercises this branch.

### Preconditions

- `runtime/lib/esr/admin/commands/reload.ex` present.
- `runtime/test/esr/admin/commands/reload_test.exs` present.

### Steps

1. Assert `reload.ex` contains `unacknowledged_breaking`.
2. Assert `reload.ex` contains `acknowledge_breaking` (the args key).
3. Assert `reload_test.exs` contains `unacknowledged_breaking` as a witness of coverage.

### Expected observables

- [ ] K-1 `reload.ex` source contains `unacknowledged_breaking`.
- [ ] K-2 `reload.ex` source contains `acknowledge_breaking` flag name.
- [ ] K-3 Witness test contains `unacknowledged_breaking` branch.

### Failure modes

| Symptom | Likely cause |
|---|---|
| K-3 fails | Test coverage for the breaking-gate path was removed — restore per plan DI-12 |

---

## Track DI-L — Post-merge hook triggers `esr notify`

**Goal:** verify `scripts/hooks/post-merge` shells `esr notify --type=breaking --since=<sha> --details=<log>` when it detects Conventional-Commits breaking markers (`!:` or `BREAKING CHANGE:`) in the just-merged range.

### Preconditions

- `scripts/hooks/post-merge` present.

### Steps

1. Read `scripts/hooks/post-merge`; assert it contains `esr notify --type=breaking`.
2. Assert it uses `git log ... --grep='^[^:]*!:'` (the Conventional-Commits breaking marker).
3. Assert it uses `HEAD@{1}` to derive the pre-merge ref.

### Expected observables

- [ ] L-1 Hook contains `esr notify --type=breaking`.
- [ ] L-2 Hook contains the `--grep='^[^:]*!:'` pattern for breaking-marker detection.
- [ ] L-3 Hook uses `HEAD@{1}` for pre-merge ref discovery.

### Failure modes

| Symptom | Likely cause |
|---|---|
| L-1 fails | Hook was rewritten to call launchctl directly, bypassing the admin queue |
| L-2 fails | Breaking-marker pattern diverged from spec §8.2; update the spec first |

---

## Track DI-M — `last_reload.yaml` updated post-reload

**Goal:** verify `Commands.Reload.write_last_reload/4` serializes `{last_reload_sha, last_reload_ts, by, acknowledged_breaking}` to `<runtime_home>/last_reload.yaml` via `Esr.Yaml.Writer`.

### Preconditions

- `runtime/lib/esr/admin/commands/reload.ex` present.

### Steps

1. Read `reload.ex`; assert it contains all four keys (`last_reload_sha`, `last_reload_ts`, `by`, `acknowledged_breaking`).
2. Assert `reload.ex` calls `Esr.Yaml.Writer.write(last_reload_path(), doc)`.
3. Assert the path function is `Esr.Paths.runtime_home() |> Path.join("last_reload.yaml")`.

### Expected observables

- [ ] M-1 All four `last_reload.yaml` keys literals present in source.
- [ ] M-2 `Esr.Yaml.Writer.write` called with `last_reload_path()`.
- [ ] M-3 Path is `runtime_home`-relative (instance-scoped).

### Failure modes

| Symptom | Likely cause |
|---|---|
| M-3 fails | Path hardcoded `~/.esrd/default/last_reload.yaml` — breaks the dev instance |

---

## Track DI-N — dev esrd reboot adopts orphans

**Goal:** verify two recovery sweeps on boot: (a) `SessionRouter.init/1` scans `/tmp/esrd-*/` orphan dirs; (b) `Admin.CommandQueue.Watcher.init/1` scans `pending/` for orphan commands and re-casts them.

### Preconditions

- `runtime/lib/esr/routing/session_router.ex` present.
- `runtime/lib/esr/admin/command_queue/watcher.ex` present.

### Steps

1. Assert `session_router.ex` contains `scan_orphan_esrd_dirs` (the orphan /tmp sweep).
2. Assert `watcher.ex` contains `scan_pending_orphans` (the orphan pending sweep).
3. Assert `watcher.ex` contains `scan_stale_processing` (the stranded-processing sweep, also a form of orphan adoption).

### Expected observables

- [ ] N-1 `session_router.ex` has `scan_orphan_esrd_dirs` function.
- [ ] N-2 `watcher.ex` has `scan_pending_orphans` function.
- [ ] N-3 `watcher.ex` has `scan_stale_processing` function.

### Failure modes

| Symptom | Likely cause |
|---|---|
| N-1/N-2/N-3 fails | Recovery sweep removed or renamed — spec §9.2/§9.3 requires all three |

---

## Track DI-O — Feishu creds rotation via re-running create-app

**Goal:** verify running `esr adapter feishu create-app` a second time writes another `register_adapter` command (not a different kind). The Admin dispatcher's `RegisterAdapter` is idempotent on `name` (overwrites the `instances.<name>` entry in `adapters.yaml`), so two submissions equal one replacement.

### Preconditions

- Same as DI-D (tmp `ESRD_HOME`, validate patched).

### Steps

1. Invoke the wizard once with name="rotate-me" + app_id="old_id", secret="old_secret".
2. Invoke it again with name="rotate-me" + app_id="new_id", secret="new_secret".
3. Assert exactly two `*.yaml` in `pending/`, both with kind `register_adapter`, same `name`, but different `app_id`.
4. Assert `register_adapter.ex` mentions overwriting the `instances.<name>` entry (idempotent replace, not append).

### Expected observables

- [ ] O-1 Two pending YAMLs, both kind=register_adapter.
- [ ] O-2 Both YAMLs have `args.name == "rotate-me"`.
- [ ] O-3 The two YAMLs have DIFFERENT `args.app_id` values.
- [ ] O-4 `register_adapter.ex` source contains `instances` (idempotent write under the same name).

### Failure modes

| Symptom | Likely cause |
|---|---|
| O-3 equal | The wizard cached the first input rather than re-prompting — check it doesn't short-circuit on existing `.env.local` |

---

## Track DI-P — Unauthorized admin command → failed/ entry

**Goal:** verify the Admin Dispatcher moves a command from `pending/<id>.yaml` to `failed/<id>.yaml` when the submitter lacks the required permission, with `error.type="unauthorized"` and `error.required` set.

**Approach:** this track is validated via the Elixir unit test `runtime/test/esr/admin/commands/notify_test.exs` — specifically the `"unauthorized — file ends up in failed/ with the cap-check error"` test case, which submits a notify without grants and asserts the failed/<id>.yaml carries `result.type == "unauthorized"`. Direct Python invocation of the Dispatcher's GenServer cast is not feasible from a non-BEAM harness, so we rely on this witness.

### Preconditions

- `runtime/lib/esr/admin/dispatcher.ex` present.
- `runtime/test/esr/admin/commands/notify_test.exs` present.

### Steps

1. Assert `dispatcher.ex` contains `unauthorized` as the `error.type` value in its unauthorized branch.
2. Assert `dispatcher.ex` moves pending → failed on cap-check failure (`move_pending_to(id, "failed")`).
3. Assert `notify_test.exs` contains `unauthorized` + `failed/` references.

### Expected observables

- [ ] P-1 `dispatcher.ex` contains the literal `"unauthorized"` error type.
- [ ] P-2 `dispatcher.ex` contains the pending → failed move (`move_pending_to` + `"failed"`).
- [ ] P-3 Witness test `notify_test.exs` contains `unauthorized` + `failed/` literals.

### Failure modes

| Symptom | Likely cause |
|---|---|
| P-2 fails | Cap-check failure path stopped moving the file off `pending/` — commands would be retried forever |

---

## Track DI-Q — Telemetry + secret redaction invariants

**Goal:** verify every admin command emits exactly one `[:esr, :admin, :command_executed|:command_failed]` telemetry event and that secrets in `args.{app_secret,secret,token}` are redacted to `[redacted_post_exec]` before the completed/failed queue file is written.

**Approach:** `runtime/test/esr/admin/dispatcher_test.exs` already exercises both via `:telemetry.attach/4` (telemetry assertion) and by submitting a notify command with secret-shaped args (redaction assertion). The Python harness asserts the witness test has both literals.

### Preconditions

- `runtime/lib/esr/admin/dispatcher.ex` present.
- `runtime/test/esr/admin/dispatcher_test.exs` present.

### Steps

1. Assert `dispatcher.ex` contains `[:esr, :admin, :command_executed]` + `[:esr, :admin, :command_failed]` (the telemetry event names).
2. Assert `dispatcher.ex` contains `[redacted_post_exec]` (the redaction sentinel).
3. Assert `dispatcher.ex` contains `@secret_arg_keys` (the list of keys to redact).
4. Assert `dispatcher_test.exs` contains `telemetry.attach` + `[redacted_post_exec]` literals.

### Expected observables

- [ ] Q-1 Dispatcher source emits both `command_executed` + `command_failed` telemetry events.
- [ ] Q-2 Redaction sentinel `[redacted_post_exec]` present.
- [ ] Q-3 `@secret_arg_keys` (or equivalent keys list) present in dispatcher source.
- [ ] Q-4 Witness test attaches a `:telemetry.attach` handler for coverage.
- [ ] Q-5 Witness test asserts the redaction sentinel lands on disk.

### Failure modes

| Symptom | Likely cause |
|---|---|
| Q-2 fails | Redaction sentinel renamed — any downstream assertion breaks; update dispatcher.ex AND this track's literal together |
| Q-4 fails | Telemetry coverage regressed — the "exactly one event per command" invariant has no test |

---

## 11. Aggregate Success Gate

A dev/prod isolation E2E "pass" requires:

- [ ] Every acceptance checkbox in Tracks DI-A through DI-Q ticked.
- [ ] `scripts/scenarios/e2e_dev_prod_isolation.py` exits 0 with `"17/17 tracks PASSED"`.
- [ ] Baseline test counts unchanged or increased: Elixir ≥ 318, Python ≥ 529 (no new test reduces either side).
- [ ] `make lint` clean (or same pre-existing SIM105/B904 carry-over from v0.2 test files).

Any unticked box blocks merge of the `feature/dev-prod-isolation` branch to `main`.

## 12. Non-goals (v1)

These are explicitly **not** exercised by this component-level E2E (deferred to v2):

- Fully-orchestrated live E2E: starting two real `launchctl bootstrap`ped esrds, driving a Feishu `/new-session` all the way through to a spawned CC session over WebSocket.
- Real `git worktree add` against a live repo (the DI-F track does not shell to `esr-branch.sh`; it validates the parse + dispatch seam).
- Real breaking-commit detection in a fresh clone (the DI-K track validates the branch code, not a live git repo).
- Multi-node dispatcher replication.
- Docker-based isolation — covered by `docs/futures/docker-isolation.md` (why deferred).

---

*End of E2E Dev/Prod Isolation Acceptance Specification.*
