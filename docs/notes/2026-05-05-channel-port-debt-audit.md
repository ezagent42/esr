# Channel-Server Port Debt Audit

**Date:** 2026-05-05
**Scope:** Tech-debt sediment from the original channel-server port + Python-side residue, ahead of Phase 2/3 plugin migration.
**Question being answered:** "Should we run a destructive cleanup pass *before* Phase 2/3, so later work is cleaner?"
**Headline:** **No BLOCKING debt found.** Phase 2/3 specs are not corrupted by current code state. Only two files qualify as "delete now"; everything else is either NOT DEBT or naturally cleaned by Phase 2/3 itself.

---

## Methodology

Three parallel agent passes, each instructed to bucket findings as:
- **DELETE NOW** — orphan, zero callers, no design implication.
- **BLOCKING** — must fix before Phase 2/3 starts, or specs' assumptions break.
- **ALONG-THE-WAY** — naturally cleaned by Phase 2 / Phase 3 / Phase 4 work.
- **TAIL** — fine to leave for Phase 4.
- **NOT DEBT** — looks suspect but the abstraction is actually correct.

The three passes covered: (1) `py/src/esr/`, (2) `runtime/lib/esr/` channel-port residue, (3) `scripts/` + `tests/` shell tooling.

---

## Bucket: DELETE NOW

| File | LOC | Why dead | Caller count |
|---|---|---|---|
| `py/src/esr/cli/daemon.py` | 237 | macOS launchctl wrapper for `esrd`. No operator currently using `uv tool install esr` path. Dev launch goes through `scripts/esrd.sh` directly. | 0 in e2e, 0 in Elixir, only self-imports inside `cli/` |
| `tests/e2e/_helpers/dev_channels_unblock.sh` | 65 | PR-186 landed in-process FCP auto-confirm. Scenario 07 calls this helper with `\|\| true` (line 126 explicitly comments "redundant safety net"). | 1 caller (scenario 07), wrapped in tolerance |

**Total reclaimable: ~302 LOC + the `websocat` runtime dependency in e2e.**

Risk: ~zero. Both files have explicit "superseded by X" markers and zero load-bearing callers.

---

## Bucket: BLOCKING (must fix before Phase 2)

**(empty)**

The Elixir-side audit specifically looked for the items I had assumed were blocking when writing the Phase 2 spec:

| Suspected blocker | Audit verdict |
|---|---|
| Reply path lacks `Esr.Slash.ReplyTarget` behaviour, hardcoded FeishuChatProxy paths | NOT DEBT — `SlashHandler.dispatch/2,3` accepts a caller-supplied `reply_to` pid; routing is adapter-agnostic. A `ReplyTarget` behaviour would add friction over the existing pid-based pattern. |
| CCProcess has 4 feishu hardcoding sites | NOT DEBT — 5 grep hits, all defensive fallbacks, none in dispatch. The "feishu" string in `build_channel_notification/2` is a default-when-absent, not an assertion. |
| `Esr.Admin.Dispatcher` conflates 3 concerns | ALONG-THE-WAY — three concerns are co-located but cleanly handler-separated; Phase 2 spec already plans the split (PR-2.4/2.5). Not blocking, just the work itself. |
| Scope.Router vs AgentSpawner inject-platform-proxy ambiguity | NOT DEBT — Router lines 8–13 are documentation residues; AgentSpawner is the actual injector and the boundary is clean. |
| cleanup_signal sender/receiver path stale | NOT DEBT — bidirectional path is intact (Dispatcher receives at L237–260, Server sends at L898). |
| `Esr.Admin.*` namespace residents | TAIL — Phase 4 PR-4.3 collapses it as planned. |

**Implication:** the Phase 2 spec's framing of "we need to split Dispatcher / introduce ReplyTarget" is **the work itself**, not preparatory cleanup. Phase 2 can start without front-loading.

---

## Bucket: ALONG-THE-WAY (cleaned by Phase 2/3 naturally)

| Item | Cleaned by |
|---|---|
| `py/src/esr/cli/main.py` (1618 LOC, 31 click commands; ~10 unused) | Phase 2 PR-2.9 — Elixir-native CLI replaces the entire Python CLI |
| `py/src/esr/cli/notify.py` (91 LOC) | Phase 2 |
| `py/src/esr/cli/reload.py` (78 LOC) | Phase 2 |
| `py/src/esr/cli/users.py` (403 LOC, scaffolding for unused PR-21a multi-user) | Phase 2 |
| `py/src/esr/cli/cap.py` + `admin.py` (319 LOC) | Phase 2 |
| `py/src/esr/cli/adapter/feishu.py` (7032 LOC — note: largely autogen + create-app wizard) | Phase 2 (Elixir port) or Phase 3 (move into feishu plugin) |
| `Esr.Admin.Dispatcher` (entire module) | Phase 2 PR-2.1 deletes |
| `Esr.Scope.Admin.bootstrap_feishu_app_adapters/1` | Phase 3 PR-3.3 moves into feishu plugin's startup hook |
| CCProcess feishu fallback strings (defensive defaults) | Phase 3 once topology is fully plugin-injected |
| Agent-browser inline calls in `pre-merge-dev-gate.sh` | Could fold into `tools/esr-debug` later — non-blocking |

---

## Bucket: TAIL (Phase 4)

| Item | Phase 4 PR |
|---|---|
| `Esr.Admin.*` namespace deletion (move `CommandQueue.Watcher` → `Esr.Slash.QueueWatcher`) | PR-4.3 |
| `permissions_registry.json` cross-language dump | PR-4.4 |
| `py/src/esr/cli/` venv removal | PR-4.7 |
| `py/src/esr/verify/` (`esr lint` tooling, ~80 LOC, zero callers) | PR-4.6 |
| `scripts/esr-cc.local.sh` (10 LOC, gitignored, operator-on-demand) | PR-4.6 if it stays unused |

---

## NOT DEBT (already correct)

- **Slash dispatch abstraction** — `SlashHandler.dispatch/2` is adapter-agnostic via caller-supplied reply pid.
- **Adapter naming** — `adapter_runner` is ESR's own naming, not a channel-server import.
- **CCProcess neighbor preference** — prefers `feishu_chat_proxy`, falls back to `cc_proxy`. The fallback is clean polymorphism, not coupling.
- **No "channel-server" / "channel_server" string mentions in code comments** — the port did not leave fingerprints.

---

## Recommendations

### Option A — Conservative (~302 LOC reclaim, zero risk)

One small PR before Phase 2 starts:
1. Delete `py/src/esr/cli/daemon.py`.
2. Delete `tests/e2e/_helpers/dev_channels_unblock.sh` + its caller line in scenario 07.
3. Run scenario 07 + 08 + 11 to confirm green.

**Recommended.** This is what the user authorized ("尽早清除"), it's purely orphan removal, and it removes the e2e `websocat` dependency.

### Option B — Moderate (~1,200 LOC reclaim)

Option A + delete `cli/notify.py`, `cli/reload.py`, `cli/users.py`, `cli/verify/` along with their click-group registrations in `main.py`. **Caveat:** requires editing `main.py` to drop the registration lines, which Phase 2 PR-2.9 will rewrite anyway. Net: doing it twice. Skip unless we want a smaller `main.py` for easier reading during Phase 2 design.

### Option C — Aggressive (delete entire `py/src/esr/cli/`)

Skip — this **is** Phase 2 PR-2.9's job. Doing it now without the Elixir replacement leaves us without an `esr` CLI in the interim.

---

## Decision needed

User picks A / B / C, or vetoes the audit's framing.

If A: I'll open a small PR (`feature/audit-immediate-cleanup`), delete the two files, run e2e, merge, then start Phase 2 PR-2.0.

If B: same PR + click-group registration edits. Larger surface, mostly mechanical.

If C: rejected by audit; we should just start Phase 2.
