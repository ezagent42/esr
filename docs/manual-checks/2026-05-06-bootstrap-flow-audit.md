# Bootstrap-flow audit — 2026-05-06

**Operator-proposed journey** (12 steps) vs **shipped surface** as of
`origin/dev` `854f1f2`.

> **Companion file:** Chinese version lives at
> [`2026-05-06-bootstrap-flow-audit.zh_cn.md`](2026-05-06-bootstrap-flow-audit.zh_cn.md).

> **Correction note (2026-05-06, rev 2):** the first revision of this
> audit was written against a stale view of the codebase (commits
> queried against `main`, not `dev`). On `dev`, `main` is **99 commits
> behind**, including the entire `plugin` mechanism build-out (spec
> [`2026-05-04-plugin-mechanism-design.md`](../superpowers/specs/2026-05-04-plugin-mechanism-design.md)
> and the `Esr.Plugin.{Loader, Manifest, EnabledList}` modules + 5
> admin commands + 5 slash routes + 2 in-tree plugins). Findings below
> are corrected against `dev`'s actual state. The first revision's
> claim "no plugin concept exists" was simply wrong.

## Methodology

Each step scored on three dimensions:

| Dim | Symbol | Meaning |
|---|---|---|
| Interface | I | An entry point exists that *could* serve this step |
| Function | F | The entry point actually delivers the expected behaviour end-to-end |
| Grammar | G | The exact wording / argument shape matches what the operator types |

Symbols: ✅ yes · ⚠️ partial · ❌ no · `[unverified]` not confirmed by inspection.

Evidence is `file_path:line` or directly-quoted code. Scope inspected:
`runtime/priv/slash-routes.default.yaml`, `runtime/lib/esr/cli/main.ex`,
`runtime/lib/esr/commands/**`, `runtime/lib/esr/plugin/**`,
`runtime/lib/esr/plugins/**`, `runtime/lib/esr/resource/capability/supervisor.ex`,
`runtime/lib/esr/users/**`, `scripts/esr*.sh`, recent specs in
`docs/superpowers/specs/2026-05-0[4,5]*.md`.

## Headline table

| # | Operator types | I | F | G | Net |
|---|---|---|---|---|---|
| 1 | `esr daemon start` | ✅ | ✅ | ✅ | works (launchd plist precondition) |
| 2 | `esr add user linyilun` (auto-admin) | ✅ | ⚠️ | ❌ | command exists; auto-admin is env-driven, not ordinal |
| 3 | `esr plugin install feishu` | ✅ | ⚠️ | ⚠️ | install verb exists; semantics is local-path, not "fetch by name" |
| 4 | `esr plugin feishu bind linyilun ou_xxx` | ✅ | ✅ | ❌ | bind is `esr user bind-feishu`, not plugin-scoped |
| 5 | `esr plugin install claude-code` | ✅ | ⚠️ | ⚠️ | same as #3; built-in by default |
| 6 | `esr plugin claude-code set config {http_proxy=…}` | ❌ | ❌ | ❌ | no `set config` verb; `required_env` is manifest-declared only |
| 7 | (Feishu) `/help` `/doctor` | ✅ | ✅ | ✅ | works as designed |
| 8 | (Feishu) `/session:new` | ✅ | ✅ | ❌ | shipped as `/new-session` or `/session new` (space, not colon) |
| 9 | (Feishu) `/workspace:add <path> worktree=test-esr` | ⚠️ | ⚠️ | ❌ | mental model differs; closest is `/new-workspace` + `/new-session worktree=…` |
| 10 | (Feishu) `/agent:add cc name=esr-developer` | ⚠️ | ⚠️ | ❌ | agents are plugin-declared; closest analog is `/plugin enable claude_code` |
| 11 | (Feishu) plain text → reply with cwd | ✅ | ✅ | ✅ | working today |
| 12 | (Feishu) `/agent:inspect esr-developer` → URL | ⚠️ | ✅ | ❌ | `/attach` returns the URL but is chat-scoped, not agent-name-scoped |

**Net read:** **9 of 12 steps work content-wise** (7 fully, 2
partially). The remaining 3 (#6 set-config, #9 workspace-add, #10
agent-add) are gated either on a missing verb (`set config`) or on a
mental-model gap (the operator imagines session→add-workspace→add-agent;
ESR ships workspace+chat→spawn-session+plugin-declared-agent). Most
single-cell failures are at the **grammar** dimension — proposed
colon-namespace + verb ordering doesn't match shipped dash/space.

---

## Step-by-step detail

### Step 1 — `esr daemon start`

| | |
|---|---|
| **I** | ✅ `runtime/lib/esr/cli/main.ex:42-101` (`cmd_daemon`) handles `start`/`stop`/`restart`/`status` and dispatches to `launchctl load -w <plist>`. |
| **F** | ✅ Works given the launchd plist exists at `~/Library/LaunchAgents/com.ezagent.esrd-<instance>.plist`. Plist is installed via `scripts/esrd-launchd.sh`. |
| **G** | ✅ Exact match. |

**Precondition surfaced:** `esr daemon start` requires the plist to
exist. First-time operators must run `bash scripts/esrd-launchd.sh
install` (or equivalent) before `esr daemon start`. The escript is
also build-only — `runtime/esr` doesn't exist on a fresh checkout
until `(cd runtime && mix escript.build)`. `CLAUDE.md` references
this; could be a single bootstrap script (e.g. `make bootstrap`).

### Step 2 — `esr add user linyilun`（自动 admin）

| | |
|---|---|
| **I** | ✅ `runtime/lib/esr/commands/user/add.ex` exists. Reachable via `esr user add` (CLI → admin queue, per `cli/main.ex:88-93` catch-all). |
| **F** | ⚠️ Adding a user works; "auto-admin for first user" is not implemented as ordinal-based but as env-driven: `runtime/lib/esr/resource/capability/supervisor.ex:maybe_bootstrap_file/1` checks `ESR_BOOTSTRAP_PRINCIPAL_ID`, and if `capabilities.yaml` is missing, seeds it with admin grant for that principal. So the chicken-and-egg of first admin IS solved — just via a different shape than the operator typed. |
| **G** | ❌ Word order is `esr user add <name>` (group-then-verb, like the existing `esr cap *`, `esr daemon *`, `esr plugin *`). Operator typed `esr add user`, which routes to slash kind `add_user` (not registered) and fails. |

**Gap clarified:** the auto-admin affordance the operator wants
exists, just driven by an env var. A spec proposing "no
ESR_BOOTSTRAP_PRINCIPAL_ID + zero users at boot → next `user add`
gets admin automatically" would close this — small mechanism on top
of the existing seeding.

### Step 3 — `esr plugin install feishu`

| | |
|---|---|
| **I** | ✅ `runtime/lib/esr/commands/plugin/install.ex` registered as slash `/plugin install` and reachable from CLI as `esr plugin install`. |
| **F** | ⚠️ Phase-1 `install` takes `<local_path>`, not `<plugin_name>` — it copies a local source directory into `runtime/lib/esr/plugins/<name>/` and validates the manifest. Spec [`2026-05-04-plugin-mechanism-design.md` §2 non-goals](../superpowers/specs/2026-05-04-plugin-mechanism-design.md#二) explicitly defers Hex / git remote installs to Phase 2. Also: feishu is **already shipped in-tree** (`runtime/lib/esr/plugins/feishu/manifest.yaml`) and **enabled by default** (`Esr.Plugin.EnabledList.legacy_default/0`), so the operator's intent ("make feishu available") is already satisfied at cold-start. Closer match for the intent: `esr plugin list` (verifies feishu is loaded) or `esr plugin enable feishu` (if it had been disabled). |
| **G** | ⚠️ The verb `install` exists; the argument shape doesn't (name vs path). |

### Step 4 — `esr plugin feishu bind linyilun ou_xxxx`

| | |
|---|---|
| **I** | ✅ `runtime/lib/esr/commands/user/bind_feishu.ex` (canonical name: `esr user bind-feishu <username> <ou_id>`). |
| **F** | ✅ Bind populates `:esr_users_by_feishu_id` ETS in `Esr.Users.Registry`; supports multiple feishu ids per user. |
| **G** | ❌ Plugin-scoped grammar (`esr plugin feishu bind ...`) doesn't match user-scoped bind (`esr user bind-feishu`). The bind mental model in code is "this user is also known on platform feishu as <ou_id>" — user-centric, not plugin-centric. |

**Worth noting:** the manifest spec ([§3, injection point #19](../superpowers/specs/2026-05-04-plugin-mechanism-design.md#三))
*does* declare a plugin-side `identity_hook` (`Esr.Plugins.Feishu.Identity.resolve_external_id/2`),
which is invoked by core `whoami`/`doctor` to resolve `ou_<id>` →
canonical username. So the *resolution* path is plugin-aware; only the
*bind* verb is in the user domain. A `esr plugin feishu bind ...`
grammar could be added as a plugin-namespaced alias if the operator
preference is strong.

### Step 5 — `esr plugin install claude-code`

Same as step 3. Important nit: plugin name is `claude_code` (snake_case,
per `runtime/lib/esr/plugins/claude_code/manifest.yaml:11`); operator
typed `claude-code` (kebab). Manifest spec [§4.1](../superpowers/specs/2026-05-04-plugin-mechanism-design.md#41-validation-rules)
says names are kebab-case-ish but the in-repo plugin uses snake_case;
worth a one-line spec consistency fix.

Note: PR-3.5 (2026-05-05) **deleted** `adapters/cc_mcp/` — the MCP server
that claude talks to is now esrd-hosted via `EsrWeb.McpController`.
No Python sidecar in the cc plugin anymore (per
`runtime/lib/esr/plugins/claude_code/manifest.yaml:14-23`).

### Step 6 — `esr plugin claude-code set config {http_proxy=…}`

| | |
|---|---|
| **I** | ❌ No `set config` verb exists. Plugin spec defines `list/info/install/enable/disable` only. |
| **F** | ❌ — |
| **G** | ❌ — |

The closest mechanism today is the manifest's `required_env:` field
(injection point #13) — plugin declares which env vars it requires;
boot-time validator fails fast if missing. But that's
*manifest-declared at compile-time*, not *operator-set at runtime*.

The operator's `set config` ask would require:
1. A new admin command (`Esr.Commands.Plugin.SetConfig`)
2. A new yaml file (`plugins.config.yaml` or similar) for per-plugin operator-overridable env
3. A reload mechanism (or "restart required" hint, matching `/plugin install`)

Spec ask for follow-up. The TODO entry "agent (cc) startup config
first-class" anticipates exactly this; the audit confirms operator-facing
shape they want.

### Step 7 — `/help` `/doctor`

| | |
|---|---|
| **I** | ✅ Both registered in `runtime/priv/slash-routes.default.yaml:25-65`. |
| **F** | ✅ `/help` renders the slash schema grouped by `category:`. `/doctor` (`runtime/lib/esr/commands/doctor.ex` — note: file moved from `admin/commands/` on dev) checks user binding + chat→workspace binding and prints "next step" hints. |
| **G** | ✅ Exact match. |

**Stale-reference nit** in `doctor.ex:67-73`: hint text references
`./esr.sh user add`. The actual entry is the `esr` escript (built via
`mix escript.build`); `esr.sh` does not exist. Worth a one-line fix
either to ship `esr.sh` (shell wrapper that defers to `esr`) or to
update the hint text to `esr user add`.

### Step 8 — `/session:new`

| | |
|---|---|
| **I** | ✅ Session creation. |
| **F** | ✅ `Esr.Commands.Session.New` wired via `slash-routes.default.yaml`. Forks a git worktree from `origin/main` per workspace's `root:` field. |
| **G** | ❌ Shipped: `/new-session` (dash) + alias `/session new` (space). The colon-namespace `/session:new` doesn't parse. |

**Cross-cutting:** ESR's slash grammar today mixes dash, space, and
no-separator forms (`/new-session`, `/session new`, `/workspace info`,
`/list-agents`). A spec adopting `/<group>:<verb>` as canonical would
let the operator-proposed form work and let the project deprecate
ad-hoc aliases.

### Step 9 — `/workspace:add /Users/.../esr worktree=test-esr`

| | |
|---|---|
| **I** | ⚠️ Closest shipped: `/new-workspace name=… root=… start_cmd=… owner=…`. Also new on dev: `/workspace describe` (operator-facing twin of LLM's `describe_topology` MCP tool) — confirms a workspace's config without modifying anything. **Neither command "adds a workspace path to a currently-running session".** |
| **F** | ⚠️ Current model is workspace-first: register the workspace (`/new-workspace`), bind chat to it (auto on creation), then `/new-session workspace=<n> name=<s> worktree=<branch>`. The operator's proposed `/workspace:add` looks like step-2 of a 2-step `/session:new + /workspace:add` mental model. The two models are structurally different. |
| **G** | ❌ — |

**Underlying mental-model gap** (unchanged from rev 1): operator
imagines `session → add workspace → add agent`; project ships
`workspace + chat → spawn session`. Worth a brainstorm before
committing — either retrofit the operator's order, or land an
operator guide that walks the current order.

Also: typo in proposed path — `/User/h2oslabs/...` should be `/Users/...`
(capital S, plural).

### Step 10 — `/agent:add cc name=esr-developer`

| | |
|---|---|
| **I** | ⚠️ No `/agent:add` slash. `/list-agents` (`runtime/lib/esr/commands/agent/list.ex`) enumerates agents. **But** agents are *plugin-declared* — `claude_code` plugin's manifest declares the `cc` agent (per [`2026-05-04-plugin-mechanism-design.md` §4 injection point #3](../superpowers/specs/2026-05-04-plugin-mechanism-design.md#四-plugin-manifest-schema)). So "add the cc agent" maps semantically to "ensure the claude_code plugin is enabled" — `esr plugin enable claude_code` (or, since it's enabled by default, do nothing). |
| **F** | ⚠️ The functional intent ("get a CC agent available") is satisfied by default; the operator-imperative `add` shape isn't. |
| **G** | ❌ — |

**Spec ask:** decide whether agents stay declarative (config-only,
plugin-shipped) or grow an imperative `add` slash. The former is
simpler; the latter matches the operator's mental model better but
brings reload-race + uniqueness-check work.

The `name=esr-developer` parameter is also worth flagging — the user
proposes per-agent **instance naming** (e.g. one chat could have
`cc:esr-developer` + `cc:reviewer`). Today the agent name is the
plugin-declared `cc`, with at most one cc-agent per session. Multi-instance
agents within a chat would be a sizable extension to the agent model.

### Step 11 — Plain text → reply containing cwd

| | |
|---|---|
| **I** | ✅ Inbound text → cc plugin's CCProcess → cc reply path is the *primary* production path. |
| **F** | ✅ Verified end-to-end by [`docs/notes/manual-e2e-verification.md`](../notes/manual-e2e-verification.md) "Single-app DM scenario" (PR-A merged) and `tests/e2e/scenarios/06_pty_attach.sh` + `07_pty_bidir.sh`. |
| **G** | ✅ — |

Specific assertion that the reply contains
`/Users/h2oslabs/Workspace/esr/.worktrees/test-esr` requires:
- Step 8/9 actually set `cwd=` to that worktree path (which is what
  `/new-session worktree=test-esr` does — see CLAUDE.md "Session URI
  shape": "`cwd` is a git worktree path (always)…");
- CC, when asked, runs `pwd` and reports.

Both are reasonable expectations of a working system.

### Step 12 — `/agent:inspect esr-developer` → browser URL of TUI

| | |
|---|---|
| **I** | ⚠️ `/attach` (`runtime/lib/esr/commands/attach.ex`) returns a clickable HTTP URL backed by xterm.js. PR-23 (Phoenix.Channel + xterm.js) and PR-24 (binary WS PTY transport) shipped this. |
| **F** | ✅ End-to-end working. |
| **G** | ❌ Two grammar gaps: (a) `/attach` resolves the *chat-current* session, not by *agent name*; (b) the proposed `/agent:inspect <name>` implies arg-driven lookup, not chat-context lookup. |

**Adjacent open question:** if the operator has multiple sessions in
the same chat (e.g. spawned via `/new-session` repeatedly with
different `name=`), `/attach` resolves to the chat-current slot only —
no way to attach to an "older" session by name. The new
`/workspace describe` (added on dev) is operator-facing inspection
that doesn't suffer this — it accepts an explicit name. An
attach-by-name (`/attach name=<s>` or `/agent inspect <s>`) would
parallel that.

---

## Cross-cutting gaps

### 1. Colon-namespace grammar (steps 8, 9, 10, 12)

The single biggest source of grammar mismatches. ESR's slash grammar
today mixes dash (`/new-session`, `/list-agents`), space
(`/workspace info`, `/plugin install`), and no-separator forms. A
consistent `<group>:<verb>` form would simplify mental load and let
several proposed slashes work without functional changes.

### 2. Operator-set per-plugin config (step 6)

Already in [`docs/futures/todo.md`](../futures/todo.md) as "Spec:
agent (cc) startup config first-class". Plugin manifest's
`required_env:` declares *what's required*, but doesn't expose an
operator-set surface. Tightly coupled to the plugin/agent boundary
discussion.

### 3. Mental-model alignment around `add` (steps 9, 10)

Project ships **declarative** flow (yaml files for workspaces / agents
/ adapter instances; `/plugin enable` + restart for plugin set);
operator imagines **imperative** flow (`/session:new` + `/workspace:add`
+ `/agent:add`). Either teach the operator the declarative model
explicitly (clear bootstrap doc with concrete order), or land
imperative slashes that wrap the declarative state changes.

### 4. First-user-auto-admin (step 2)

Mechanism exists (`ESR_BOOTSTRAP_PRINCIPAL_ID` env), but it requires
the operator to know to set the env. A friendlier default — "if no
admin grant exists in capabilities.yaml when `user add` runs, grant
admin to that user" — is small (~30 LOC in `Esr.Resource.Capability.Supervisor`)
and would let the operator skip the env-var step.

### 5. `esr.sh` references (steps 1, 7)

`doctor.ex:67-73` and possibly other hint-text references advertise
`./esr.sh user add` etc. The actual entry on dev is the `esr` escript
at `runtime/esr` (built via `mix escript.build`); `esr.sh` does not
exist on disk. Either ship a thin wrapper `scripts/esr.sh` that defers
to the escript, or update hint text to use `esr` directly.

---

## Recommended specs to file

Roughly ordered by leverage (impact ÷ effort):

1. **Stale `esr.sh` reference fix** — 1-LOC: replace `./esr.sh` with
   `esr` in `doctor.ex` hint text. Or ship `scripts/esr.sh` as a thin
   `exec ./esr "$@"` wrapper after the escript builds.
2. **First-user-auto-admin extension** — small; on `user add` invocation
   when capabilities.yaml has no admin grants yet, default-grant to the
   added user. Subsumes `ESR_BOOTSTRAP_PRINCIPAL_ID` for the common case.
3. **Spec: colon-namespace slash grammar** — decide canonical form
   (`<group>:<verb>` proposed by operator); update
   `slash-routes.default.yaml` to ship `/session:new` etc. as primary;
   keep dash forms as deprecated aliases for one release.
4. **Spec: operator-set per-plugin config** — `/plugin <name> set
   config <key>=<value>` writing to a plugins.config.yaml (sibling of
   plugins.yaml); `restart required` hint matching `/plugin install`.
   Subsumes the TODO "agent (cc) startup config first-class".
5. **Spec: imperative `add` verbs (or document declarative flow)** —
   either land `/session:new` → `/workspace:add` → `/agent:add` as
   wrappers around the declarative state changes, or ship a
   `docs/guides/first-time-operator.md` walking the current
   workspace-first order. Cheaper to document; more invasive to
   retrofit.

---

## See also

- [`docs/notes/manual-e2e-verification.md`](../notes/manual-e2e-verification.md)
  — manual *post-release* verification of an already-running system.
  Complements `make e2e`.
- [`docs/dev-flow.md`](../dev-flow.md) — the `feature → dev → main`
  flow this audit was written under.
- [`runtime/priv/slash-routes.default.yaml`](../../runtime/priv/slash-routes.default.yaml)
  — canonical slash command source.
- [`docs/superpowers/specs/2026-05-04-plugin-mechanism-design.md`](../superpowers/specs/2026-05-04-plugin-mechanism-design.md)
  — plugin mechanism spec rev 5 (the spec this audit's plugin
  findings cite throughout).
- [`docs/superpowers/specs/2026-05-05-plugin-physical-migration.md`](../superpowers/specs/2026-05-05-plugin-physical-migration.md)
  — plugin physical migration (Phase 3).
- [`docs/futures/todo.md`](../futures/todo.md) — durable TODO list;
  several items in this audit map to existing entries there.
