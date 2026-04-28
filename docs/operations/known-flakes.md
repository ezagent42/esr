# Known Test Flakes

**Last updated**: 2026-04-28

This document lists test failures that appear intermittently and the reason we've accepted them as known-flake rather than blocking merges. Each entry has a concrete follow-up path.

---

## 1. `Esr.PeerServerLaneBTest` — "admin wildcard bypasses both inbound_event and tool_invoke"

**File**: `runtime/test/esr/peer_server_lane_b_test.exs:188`

**Symptom**:
```
Assertion failed, no matching message after 1000ms (or 3000ms)
mailbox:
  pattern: %Phoenix.Socket.Broadcast{event: "envelope", payload: env}
  value:   {#Reference<...>, :timeout}
  value:   {:DOWN, #Reference<...>, :process, #PID<...>, :normal}
```

**Rate**: ~20-40% under default `max_cases: 56`; persists (though less frequently) at `max_cases: 1`.

**Root cause (investigated 2026-04-22)**: `{Ref, :timeout}` residue indicates a late `GenServer.call` reply. Under load, shared singletons (`Esr.Capabilities.Grants`, `EsrWeb.Endpoint` Registry, DynamicSupervisor backing `start_supervised/1`) queue up and miss their 5s default timeout. Even serial test execution sees this flake occasionally, suggesting background fs_event watchers + `Process.send_after`-based timers accumulate state across tests.

**Reproducibility**: intermittent even at `--max-cases 1`.

**Workaround**: rerun (`mix test --failed` typically passes).

**Permanent fix**: the v3.1 Peer/Session refactor (tracked in `docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md`, not in this branch) will introduce Session-scoped capability projection — see `docs/futures/peer-session-capability-projection.md` for details. That refactor replaces the single shared `Grants` GenServer with per-Session projections and eliminates the cross-test contention.

---

## 2. `Esr.Admin.Commands.CapTest` — "Grant.execute/1 persists through an explicit FileLoader reload (Watcher contract)"

**File**: `runtime/test/esr/admin/commands/cap_test.exs:149`

**Symptom**:
```
match (=) failed
code:  assert :ok = FileLoader.load(path)
left:  :ok
right: {:error, {:unknown_permission, "session.create", "ou_loader_test"}}
```

**Rate**: ~10-20% under default concurrency.

**Root cause**: Test isolates `ESRD_HOME` via `System.put_env` into a `tmp/` directory for `capabilities.yaml` but does NOT isolate `permissions_registry.json`. A different test that concurrently modifies the permissions registry can cause this test's `FileLoader.load/1` to see an older registry that doesn't include the test's freshly-granted permission.

**Workaround**: rerun.

**Permanent fix**: same as #1 — the v3.1 refactor's per-Session projection sidesteps the shared-file-state problem. Short-term alternative: isolate `permissions_registry.json` per-test, similar to `capabilities.yaml`; deferred because it requires duplicating the test-isolation protocol in 5+ files.

---

## 3. `Esr.AdminSessionBootstrapFeishuTest` — bootstrap helpers see `:test_admin_children` already-dead

**File**: `runtime/test/esr/admin_session_bootstrap_feishu_test.exs:45` and `:80`

**Symptom**:
```
** (exit) exited in: GenServer.call(:test_admin_children, {:start_child, ...}, :infinity)
    ** (EXIT) no process: the process is not alive or there's no process
       currently associated with the given name, possibly because its
       application isn't started
```

**Rate**: ~5-10% under default concurrency.

**Root cause (observed 2026-04-28)**: Test allocates a per-test
`DynamicSupervisor` registered as `:test_admin_children` and uses it
to host `FeishuAppAdapter` children. Under concurrent test load, the
supervisor's owner process can be torn down (or never come up under
contention) by the time `bootstrap_feishu_app_adapters/1` calls
`DynamicSupervisor.start_child/2`. Same root-cause family as #1/#2 —
shared/test-singleton process registration races.

**Workaround**: rerun (`mix test --failed`).

**Permanent fix**: same as #1/#2 — v3.1 per-Session projection.
Short-term alternative: stub `:test_admin_children` registration into
the test's `setup` block with explicit `start_supervised/1` so ExUnit
owns the lifecycle.

---

## 4. `Esr.AdminSessionSlashHandlerBootTest` — `slash_handler_ref/0` returns `:error`

**File**: `runtime/test/esr/admin_session_slash_handler_boot_test.exs:12`

**Symptom**:
```
match (=) failed
code:  assert {:ok, pid} = Esr.AdminSessionProcess.slash_handler_ref()
left:  {:ok, pid}
right: :error
```

**Rate**: ~5-10% under default concurrency.

**Root cause (observed 2026-04-28)**: `slash_handler_ref/0` reads from
a `Process.put`/`Process.get`-backed registry seeded during admin
session boot. Under concurrent test load the boot path can finish
*after* the test's first assertion fires. Race window is narrow but
real — test predates the v3.1 lifecycle hardening.

**Workaround**: rerun.

**Permanent fix**: same family — v3.1 refactor moves slash handler
registration to a deterministic supervised child and eliminates the
boot-completion race.

---

## Guidance

- **CI failures**: if only these two tests fail and `mix test --failed` then passes, re-approve. If other tests fail intermittently, file a new entry here.
- **Root cause for all**: the singleton `Esr.Capabilities.Grants` + global `permissions_registry.json` + admin-session bootstrap singletons = shared mutable state across tests, not adequately isolated. The test suite predates the v3.1 refactor's Session-scoped model.

## Adding a new entry

When you observe a new flake variant, follow the existing 4-section
template (Symptom / Rate / Root cause / Workaround + Permanent fix).
**Don't silence the test** — let it remain in the suite so the
permanent-fix work has a regression target. Update the "Last updated"
date.
