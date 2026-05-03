# ESR Concept Rename Map — current code → metamodel vocabulary

**Date:** 2026-05-03 (rev 2 — applied subagent review fixes)
**Audience:** anyone executing the post-metamodel refactor
**Status:** prescriptive plan; lists which modules rename when, in which batch, with what blast radius. Not the metamodel itself — see `concepts.md` / `session.md` / `mechanics.md` for that.

---

## 一、What this doc is

`concepts.md` defines target vocabulary (Scope / Entity / Resource / Interface + Session). This doc maps **today's Elixir + Python module names** onto that vocabulary, classifies each rename, and proposes batch order for the refactor.

The user's flow (from chat 2026-05-03) is the spine:

1. Rename what cleanly maps + update touched docs
2. Run e2e to confirm nothing broke
3. Restructure what doesn't cleanly map + update docs
4. Re-run tests after each step
5. Add new declarative Sessions etc.
6. Update e2e for new features

This doc covers **steps 1 + 3** — what gets renamed mechanically, what needs a separate spec.

---

## 二、Naming key

| Mark | Meaning | Action |
|---|---|---|
| ✅ | Mechanical rename — single-token swap, no semantics change. Safe via LSP rename + grep sweep. | Phase 1 |
| ⚠️ | Mostly mechanical — wider blast radius (touches many call-sites or @behaviour lines), but still no structural change. | Phase 2 |
| 🔧 | Structural — current code conflates two metamodel concepts; rename + split is needed. Requires separate design spec. | Phase 3 |
| ⏹ | Stays as-is — already aligned, or framework-level / domain-neutral. | Do not rename |
| ❓ | Unclear — needs user decision before classifying. | Discuss before scheduling |

---

## 三、Phase 1 — Mechanical renames (✅)

Token swap `Session*` → `Scope*` on the **runtime-instance** layer. The new declarative `Esr.Sessions.*` namespace is added later (Phase 4 / new-feature work) without colliding with these.

| Current | New | Role | Notes |
|---|---|---|---|
| `Esr.Session` | `Esr.Scope` | Per-Scope subtree supervisor (`:one_for_all :transient`) | Touches every `Session.start_link` / `Session.supervisor_name/1` call |
| `Esr.SessionProcess` | `Esr.ScopeProcess` | The Scope's state GenServer (`session_id`, agent_name, grants cache, chat_thread_key) | Touches every `GenServer.call(SessionProcess, …)` |
| `Esr.SessionRouter` | `Esr.ScopeRouter` | Control-plane coordinator for Scope lifecycle (`create_session_sync`, `end_session_sync`, `new_chat_thread`) | The 3 sync messages & the PubSub topic `"session_router"` rename in lockstep |
| `Esr.SessionsSupervisor` | `Esr.ScopesSupervisor` | DynamicSupervisor that owns all live Scope subtrees | Touches application supervision tree |
| `Esr.AdminSession` | `Esr.AdminScope` | Always-on Scope hosting session-less Entities (FeishuAppAdapter, SlashHandler, pools) | Atom config `:esr, :admin_children_sup_name` callers stay correct (atom unchanged) |
| `Esr.AdminSessionProcess` | `Esr.AdminScopeProcess` | Admin-Scope state GenServer (parallel to ScopeProcess) | |
| `Esr.Admin.Commands.Session.*` (6 modules: `New`, `End`, `BranchNew`, `BranchEnd`, `List`, `Switch`) | `Esr.Admin.Commands.Scope.*` | Slash-command Handler-composing Entities operating on Scopes | Directory-level rename; same R1 PR. The commands operate on Scope instances, not Session declarations |

**Renamed identifiers (non-module, swept in same batch):**

- `session_id` field name in YAML / structs / log keys — **stays as-is**. The metamodel says "Scope is the runtime instance of a Session description" — `session_id` is fine because the ID identifies "an instance of a Session description" = a Scope. Renaming this would touch every YAML file, every log line, every API. Out of scope for the mechanical batch; revisit only if user explicitly wants `scope_id` everywhere.
- Module-internal var names (`session_pid`, `session_name`, etc.) — rename in same PR for module-level consistency.

---

## 四、Phase 2 — Mostly mechanical (⚠️) — `Peer*` → `Entity*`

Wide blast radius: every concrete actor module declares `@behaviour Esr.Peer.Proxy` or `@behaviour Esr.Peer.Stateful`, and PeerServer is referenced from many call sites. But no structural change — just token swap.

| Current | New | Role |
|---|---|---|
| `Esr.Peer` | `Esr.Entity` | Base behaviour (`peer_kind/0` callback, two flavors `:proxy` and `:stateful`) |
| `Esr.Peer.Proxy` | `Esr.Entity.Proxy` | Behaviour for proxy-type entities |
| `Esr.Peer.Stateful` | `Esr.Entity.Stateful` | Behaviour for stateful entities |
| `Esr.PeerServer` | `Esr.EntityServer` | GenServer host for a single live entity (inbound dedup, handler-router call, persistence) |
| `Esr.PeerRegistry` | `Esr.EntityRegistry` | actor_id → pid registry |
| `Esr.PeerFactory` | `Esr.EntityFactory` | spawn / terminate / restart for entities |
| `Esr.PeerPool` | `Esr.EntityPool` | Bounded pool of `Entity.Stateful` workers (max 128) |
| `Esr.PeerSupervisor` | `Esr.EntitySupervisor` | DynamicSupervisor under each Scope, owns EntityServer pids |
| `Esr.Peers.*` (namespace) | `Esr.Entities.*` | Namespace for concrete entity modules (`cc_process`, `pty_process`, `feishu_app_adapter`, …) |

**Why ⚠️ not ✅:** every concrete Entity module's `@behaviour` line moves; the `:peer_kind` field shows up in many places (logs, telemetry events, registry keys). LSP rename catches the module refs but not raw atom uses — must follow with `grep -rn ':peer'` sweep.

**Sibling namespace `Esr.Workers.*`** — `Esr.Workers.AdapterProcess` and `Esr.Workers.HandlerProcess` both `use Esr.Peer.Stateful`, so the macro rewrites mechanically when the behaviour renames. **Module names stay** (`Esr.Workers.*`) — `Workers` is an infrastructure namespace for erlexec-isolated subprocess hosts, not a metamodel concept. Phase 2 PR touches the `use` line inside these modules but doesn't move them to `Esr.Entities.*`. `Esr.WorkerSupervisor` likewise stays.

**Open question (❓):** the term "peer" is also used in operator vocabulary (`Esr.PeerRegistry` lookups in slash commands, telemetry event names like `[:esr, :peer, …]`). Renaming telemetry event names is breaking for any external dashboards. **Recommend**: rename the modules + behaviour names; **keep** existing telemetry event-name atoms (`:peer`) for at least one release; add a parallel `:entity` event in a separate PR.

---

## 五、Phase 3 — Structural (🔧) — needs separate spec

Concepts that the new metamodel separates but current code conflates. Each needs a small design spec before the rename PR.

### 🔧-1. `Esr.SessionRegistry` is three things in one

Today `Esr.SessionRegistry` does:
1. YAML-compiled `agents.yaml` cache (with hot-reload)
2. `(chat_id, app_id) → session_id` routing lookup
3. `(session_id, peer_name) → pid` lookup

The metamodel says these are **three different Resources**:
- (1) is a `Registry` Resource holding declarative agent definitions — propose `Esr.AgentRegistry` or fold into a generic yaml-cache façade
- (2) is the Scope-routing concern (entry-point for inbound) — propose `Esr.ScopeRouterRegistry` or merge into `Esr.ScopeRouter`
- (3) is the Entity-locator concern — overlaps with `Esr.PeerRegistry` (actor_id → pid) but keyed on `(scope_id, entity_name)` instead. May consolidate.

**Spec needed:** which split, naming, migration path. Out of scope for mechanical PRs.

### 🔧-2. `Esr.SessionSocketRegistry` naming reuse

The `SessionRegistry` name was historically taken by today's CC WS socket bindings, then renamed to `SessionSocketRegistry` to free `SessionRegistry` for yaml-topology (current state). After the Phase 1 rename `Session* → Scope*`, this becomes `Esr.ScopeSocketRegistry` — but the role is "CC WebSocket bindings for a CLI adapter," which has nothing to do with Scope identity. ❓ Needs user choice between:
- `Esr.ScopeSocketRegistry` (mechanical token swap)
- `Esr.CliSocketRegistry` (renames to actual role; the CC adapter's CLI socket binding)
- `Esr.AttachSocketRegistry` (renames to PR-22's attach-socket concern)
- `Esr.AdapterSocketRegistry` (most adapter-agnostic — accommodates future Cursor / Aider / etc. CLI adapters that would also bind a socket here)

### 🔧-3. `Esr.Capabilities` + `Esr.Permissions` — Resource vs. Interface split

Today `Esr.Capabilities` and `Esr.Permissions` are both monolithic façades with parallel structure (façade module + `<Name>.Registry` + `<Name>.Bootstrap`). Metamodel says:
- **Capability Resource** = the token + grant binding (data)
- `CapabilityDeclarationInterface` (name / description / required-for) — implemented by code declarations
- `GrantInterface` (grant / revoke / check) — implemented by registry

`Esr.Permissions` mirrors the same shape; its review must travel with Capabilities.

**Spec needed:** whether to physically split modules, or stay as façade. Likely lighter touch (façades stay; doc cross-reference to interface contracts). Bundle both subsystems into one spec.

### 🔧-4. Workspace's metamodel role

`Esr.Workspaces.Registry` holds workspaces.yaml cache. **Is "workspace" a Scope, a Resource, or an Entity-attribute?** In the metamodel:
- A workspace bounds permissions + dirs — feels Scope-like (has members)
- But workspaces are referenced by Entities (a User belongs to a workspace) — feels like a Scope reference
- Spec needed before any rename here. Until then, ⏹ stays as-is.

---

## 六、Stays as-is (⏹)

These are already aligned, framework-level, or domain-neutral. **Do not rename in mechanical batches.**

### Elixir — metamodel-aligned

| Module | Why stays |
|---|---|
| `Esr.Topology` | Topology is a metamodel facet name; module already accurate |
| `Esr.HandlerRouter`, `Esr.Handler` | Handler is an Entity-base in the metamodel; name is correct |
| `Esr.Admin.Dispatcher`, `Esr.Admin.Supervisor`, `Esr.Admin.CommandQueue.{Watcher,Janitor}` | Admin subsystem internals; Dispatcher is a Handler-composing Entity, others are infrastructure |
| `Esr.Role` | Internal taxonomy of OTP-actor roles; not a metamodel-level concept |
| `Esr.SlashRoutes` | Per `session.md §六`, this IS the SlashRouteRegistry instance — name aligns |
| `Esr.DeadLetter` | A bounded JobQueue Resource instance; current name is the role-name |
| `Esr.Workspaces.Registry`, `Esr.Users.Registry` | Both are Registry Resource instances; names are accurate |
| `Esr.Yaml.*` | Yaml is implementation detail (Registry persistence backing); naming stays |

### Elixir — infrastructure / framework-level (no metamodel concept)

| Module | Role |
|---|---|
| `Esr.Application` | Top-level OTP application boot |
| `Esr.Uri` | URI parser/builder utility |
| `Esr.Paths` | Path helpers |
| `Esr.AnsiStrip` | ANSI-escape utility |
| `Esr.OSProcess`, `Esr.PyProcess` | erlexec subprocess hosts (foundation under `Esr.Workers.*`) |
| `Esr.Worktree` | Git worktree wrapper for `/new-session` |
| `Esr.Workers.*`, `Esr.WorkerSupervisor` | Subprocess-isolation infrastructure (erlexec-driven); sibling to `Esr.Entity*` rename — see §四 |
| `Esr.Telemetry.*` (attach, buffer, supervisor) | Telemetry plumbing |
| `Esr.Persistence.*` (ets, supervisor) | ETS-backed persistence |
| `Esr.Pools` | Pool startup glue |
| `Esr.Launchd.*` | macOS launchd integration |
| `EsrWeb.*` | Phoenix endpoint layer; metamodel-agnostic. ⚠️ `EsrWeb.ChannelChannel` / `EsrWeb.ChannelSocket` naming awkwardness flagged for a future doc spec, NOT mechanical |

### Python

| Package | Why stays |
|---|---|
| `esr` (SDK) | Public SDK package; renaming would break all adapter shipped code |
| `_adapter_common`, `_ipc_common`, `_voice_common` | Internal helpers; underscore prefix marks them; metamodel-agnostic |
| `cc_adapter_runner`, `feishu_adapter_runner`, `generic_adapter_runner` | Adapter Entity instances — names are domain-specific by design |
| `voice_asr`, `voice_tts`, `voice_e2e` | Voice subsystem instances; metamodel-agnostic |

---

## 七、Phase ordering (PR sequence)

Smallest blast radius first; each PR ends green (e2e 06+07 + DOM dataset check).

| PR | Contents | Blast radius | Validation |
|---|---|---|---|
| **R1** | Phase 1 batch — `Esr.Session*` → `Esr.Scope*` (6 modules) | ~80 files, mostly Elixir + a few yaml/doc refs | mix test + uv run pytest + e2e 06/07 |
| **R2** | Phase 2 batch — `Esr.Peer*` → `Esr.Entity*` (8 modules + namespace + behaviour names) | ~150 files (every concrete entity module's `@behaviour`) | mix test + uv run pytest + e2e 06/07; telemetry events untouched |
| **R3 spec** | Phase 3-1 design — split `Esr.SessionRegistry` → 3 Registries | spec only, no code | subagent review |
| **R3 impl** | Phase 3-1 implementation | ~30 files | mix test + e2e 06/07 |
| **R4 spec + impl** | Phase 3-2 — `Esr.SessionSocketRegistry` final name | small | mix test + e2e 06/07 |
| **R5 spec** | Phase 3-3 — Capabilities Resource / Interface split | spec only, likely doc-only outcome | subagent review |
| **R6 spec** | Phase 3-4 — Workspace's metamodel role | spec only | subagent review |

After R1+R2 land, the codebase is "mechanical-rename complete" — every Session→Scope and Peer→Entity rename is done. Phase 3 specs can be drafted concurrently with R1/R2 implementation work.

---

## 八、Per-PR procedure

For each rename batch (R1, R2):

1. **Preflight**
   - On `dev`, freshly synced. New branch `refactor/r<N>-<name>`.
   - Run baseline: `make e2e` (06+07 minimum) + DOM-dataset check via the same Chrome incantation as the pre-merge-dev gate.

2. **Identify scope**
   - Grep raw: `grep -rn 'Esr\.OldName\b' runtime/ --include='*.ex' --include='*.exs' --include='*.eex' --include='*.yaml' --include='*.yml' --include='*.md' | sort -u`
   - Save count to a file in the PR branch as `docs/refactor/r<N>-grep-pre.txt` for delta verification.

3. **LSP rename (Elixir)**
   - In editor with ElixirLS (Workspace = `runtime/`): rename module via "Rename Symbol" — this updates module declarations + Elixir imports/aliases + struct refs.
   - For each renamed module, ElixirLS may miss: raw atom uses (`:peer`), string interpolations (`"Esr.Peer..."`), telemetry event keys.

4. **Manual sweep (the bits LSP misses)**
   - `grep -rn 'OldName' runtime/` — any remaining hit is either a rename target or an intentional reference (telemetry event name, log key, etc.).
   - Decide per-hit: rename or document why kept.

5. **Python sweep (if any cross-language refs)**
   - `grep -rn 'OldName' py/ adapters/ tests/` — most should be zero hits since Python doesn't import Elixir modules. Anything found is usually a string literal in a test fixture or yaml.
   - Pyright/pylance LSP for `_adapter_common` etc. covers Python-internal renames if needed.

6. **Compile + test**
   - `mix compile --warnings-as-errors` (force-recompile if .beam mtime suspicious — see memory rule "Force compile after diagnostic edits")
   - `(cd runtime && mix test)`
   - `(cd py && uv run pytest)`
   - `bash tests/e2e/scenarios/06_pty_attach.sh && bash tests/e2e/scenarios/07_pty_bidir.sh`
   - DOM dataset check: same Chrome incantation as `scripts/hooks/pre-merge-dev-gate.sh` step 2b

7. **Doc updates in same PR**
   - `docs/architecture.md`, `README.md`, `runtime/README.md` if module names appear
   - `docs/notes/{concepts,session,mechanics}.md` — only if rename affects example names
   - `CLAUDE.md` if any rename affects how Claude is told to navigate the code

8. **Open PR + merge**
   - `gh pr create --base dev` per git-flow
   - Pre-merge-dev gate hook auto-runs 06+07+DOM check; if any check fails, fix before retry.

---

## 九、Python rename strategy

Python side is mostly insulated — packages are domain-named (`feishu_adapter_runner`, `cc_adapter_runner`, etc.) and don't reference Elixir module names. **Most rename PRs touch zero Python files.**

If Python refs do appear (typically in `py/src/esr/` SDK or test fixtures with hard-coded module names):
- LSP via pyright (or pylance in VSCode) covers explicit `import` rewrites
- Duck-typed string refs caught by `grep -rn 'OldName' py/`
- `(cd py && uv run pytest)` is the safety net — Python's late binding means a missed rename surfaces only at test-runtime, not at import-time. Pytest runs full module loading on collection, so any import-level break shows up immediately.

If a Python rename is mechanical-but-large (e.g. an SDK function rename), give it its own PR. Don't bundle Python refactors into Elixir-driven rename PRs.

---

## 十、Open questions (❓) — flag for user

Before scheduling R1/R2, decide:

1. **Telemetry event names** — keep `:peer` / `:session` event keys for backwards-compat, or rename in lockstep? (Recommendation: keep until grep of repo + external dashboards confirms no out-of-tree consumer; then sunset. Add `:entity`/`:scope` event keys in parallel if needed.)
2. **`session_id` field name** — universally rename to `scope_id`, or keep `session_id` since it identifies "an instance of a Session description"? (Recommendation: keep as grandfathered. New code/fields prefer `scope_id` to avoid future yaml-side `session_name` collision when declarative Sessions land.)
3. **`Esr.SessionSocketRegistry`** — pick: `ScopeSocketRegistry` (mechanical) / `CliSocketRegistry` (role-named, CC-only today) / `AttachSocketRegistry` (PR-22 concern-named) / `AdapterSocketRegistry` (most adapter-agnostic for future Cursor/Aider/etc.). (Recommendation: `AdapterSocketRegistry` — survives addition of new CLI adapters without renaming again.)
4. **Workspace** — Scope or Resource? Spec needed before any rename. (Recommendation: leave for R6 standalone spec; do not touch in R1/R2.)

---

## 十一、Related docs

- `docs/notes/concepts.md` — metamodel definition (must read first)
- `docs/notes/session.md` — Session catalog + Entity / Resource declarations
- `docs/notes/mechanics.md` — runtime essence (5 buckets + actor model)
- `docs/futures/todo.md` — refactor task tracking
- `scripts/hooks/pre-merge-dev-gate.sh` — the gate that enforces e2e 06+07 + DOM dataset on every dev merge
