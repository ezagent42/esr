# Phase 2 — slash / CLI / REPL / admin unification (Elixir-native)
# 第二阶段 — slash / CLI / REPL / admin 四路统一（Elixir 原生化）

**Date / 日期:** 2026-05-05
**Status / 状态:** Draft for user review / 草案，待用户评审。
**Predecessor / 前序:** PR-180/181/182/183/184/185/186/187 (Phase 1 plugin foundation, 2026-05-04 / 第一阶段 plugin 基础设施)。
**Successor / 后继:** Phase 3 (`docs/superpowers/specs/2026-05-05-plugin-physical-migration.md`) consumes this contract / 第三阶段 plugin 物理迁移消费本阶段确立的契约。

> **本规格说明书采用中英双语写作（English + 中文）**: 每个大节先英文叙述设计意图，再用中文总结要点。代码块、文件路径、模块名保持英文以避免歧义。
>
> **This spec is bilingual (English + Chinese)**: each major section presents the design in English, then summarizes the key points in Chinese. Code blocks, file paths, and module names stay in English to avoid ambiguity.

---

## 一、Why this phase exists / 为什么需要这个阶段

> **中文要点**:
> 今天有四条独立的"按 kind+args 执行"代码路径：(1) chat slash 入站、(2) admin queue 文件、(3) Python click CLI 共 ~2872 LOC、(4) 还没有 REPL。PR-21κ (2026-04-30) 已经把 Elixir 侧的 dispatch 表合并到单一 yaml schema，本阶段完成最后一步：把 dispatch *模块* 也统一，把 Python 手写 click 替换为 schema-驱动的 Elixir 原生 CLI，并新增 REPL 作为操作员默认入口。
>
> **目标**: 单一 dispatch 路径（删 `Esr.Admin.Dispatcher`，但其独占的 cleanup_signal rendezvous + secret redaction + 文件状态机迁移到新模块 `Esr.Slash.CleanupRendezvous` + `Esr.Slash.QueueResult`）；schema 驱动的 CLI；REPL；plugin 贡献 schema 片段后自动出现在 chat / CLI / REPL 三处。
>
> **价值不在删代码而在契约统一** — 实际净删约 100 LOC（之前误估 ~2500 是错的；review 发现 `main.py` 大部分命令不在 slash schema 范围内）。


Today, four separate code paths "execute a kind with args":

1. **Slash inbound** — chat user types `/foo bar=baz`; FAA → FCP → `Esr.Entity.SlashHandler.dispatch/3` → `Esr.Admin.Commands.<Mod>.execute/2`.
2. **Admin queue file** — operator `esr admin submit foo --arg bar=baz`; Python writes yaml to `~/.esrd/<env>/admin_queue/pending/<id>.yaml`; `Esr.Admin.CommandQueue.Watcher` reads it; `Esr.Admin.Dispatcher.run_command/2` permission-checks + invokes the same `Esr.Admin.Commands.<Mod>.execute/2`.
3. **Python click groups** — hand-written `cli/cap.py`, `cli/users.py`, `cli/daemon.py` etc. (~2872 LOC total). Each click subcommand independently calls admin queue submission OR reads JSON dumps from disk. **Schema decoupled from `slash-routes.yaml`** — adding a new command requires editing both Elixir and Python.
4. **No REPL** — the operator currently strings together shell invocations of `esr admin submit ...` to do anything interactive.

PR-21κ (2026-04-30) collapsed the Elixir-side dispatch tables into a single yaml schema. **Phase 2 finishes the job**: collapse the dispatch *modules* too, replace Python click hand-writing with schema-driven Elixir-native CLI, and add a REPL as the operator's default entry point.

### Goals

1. Single Elixir dispatch path. `Esr.Entity.SlashHandler` is the only entry point; `Esr.Admin.Dispatcher` is deleted.
2. Schema-driven CLI: the `esr` binary reads the same `slash-routes.yaml` and exposes every kind as a CLI subcommand automatically.
3. REPL: `esr` with no arguments enters an interactive shell that accepts slash text directly, with autocomplete sourced from the schema.
4. Net delete of ~2500+ LOC (Python CLI 2872 + `Admin.Dispatcher` ~200 + watcher slim ~100 - new Elixir CLI ~800).
5. Plugin manifest's `slash_routes:` fragment, when merged into the registry, immediately exposes new commands to slash chat **and** the Elixir CLI **and** REPL autocomplete — zero code added.

### Non-goals

- **Plugin physical migration** — Phase 3 consumes this contract but is out of scope here.
- **Auth model changes** — operator principal still comes from `ESR_OPERATOR_PRINCIPAL_ID` env (or chat sender for inbound). Auth design separate.
- **Replacing the admin_queue/pending file transport** — files stay; operators / external scripts can still write yaml files directly. Watcher's logic just slims down to "read file, hand to SlashHandler".

---

## 二、Architecture / 架构

> **中文要点**:
> **单一 dispatch 路径**：任意来源（chat / file / escript / REPL / HTTP）→ 生成 `SlashEnvelope { slash_text, principal_id, reply_to }` → `Esr.Entity.SlashHandler.dispatch/3` 是唯一入口 → 查 `SlashRoute.Registry` → 检查 capability → 调 `command_module.execute/2` → 通过 `reply_to` 把结果送回。
>
> **`reply_to` 抽象成 behaviour**：`Esr.Slash.ReplyTarget` 接口，4 个实现 — `ChatPid`（chat 出站）/ `QueueFile`（写 yaml 文件）/ `IO`（escript 单次执行打印 stdout）/ `WS`（REPL 通过 Phoenix.Channel 推送）。
>
> **`Admin.Dispatcher` 不是简单 duplicate**：它独占 3 个职责（cleanup_signal rendezvous、result 时的 secret 脱敏、pending→processing→completed 的文件状态机），需要拆分迁移到新的 `Esr.Slash.CleanupRendezvous` + `Esr.Slash.QueueResult` 模块。
>
> **`internal_kinds:` 不能扁平合并到 `slashes:`**：会改变安全边界（grant/revoke 等 operator-only 命令将变成 chat 可调用，凡是有 cap.manage 的人能在 chat 里给自己授权，提权风险）。保留 internal_kinds 作为独立子命名空间。

### Single dispatch path

```
ANY entry (chat / file / escript / REPL / HTTP)
        ↓ produces SlashEnvelope:
        {
          slash_text:   "/foo bar=baz" | parsed_command_map,
          principal_id: <chat_sender_id | operator_principal_id>,
          reply_to:     callback_pid_or_writer
        }
        ↓
   Esr.Entity.SlashHandler.dispatch/3        ← THE entry
        ↓
   Esr.Resource.SlashRoute.Registry.lookup   ← kind → permission + command_module
        ↓
   Esr.Resource.Capability.has?              ← permission check
        ↓
   command_module.execute/2                  ← business logic (unchanged)
        ↓
   reply_to.send_response(result)            ← chat outbound | yaml write | stdout | WS push
```

### What survives, what dies

| Module | Status | Reason |
|---|---|---|
| `Esr.Resource.SlashRoute.Registry` | survives | single source of truth, unchanged |
| `Esr.Interface.SlashParse` | survives | text → command_map parser, unchanged |
| `Esr.Entity.SlashHandler` | **expanded** | becomes universal entry; gains `reply_to` abstraction |
| `Esr.Admin.Dispatcher` | **split, then deleted** | dispatch + permission check migrate to `SlashHandler`; the queue-specific responsibilities (cleanup_signal rendezvous, secret redaction on result, pending→processing→completed file state machine) migrate to a NEW `Esr.Slash.QueueResult` (and `register_cleanup/2` API stays accessible via this module). See "Admin.Dispatcher actually does THREE things" below. |
| `Esr.Admin.CommandQueue.Watcher` | **slimmed** | retains file_system watch + boot-time stale-`processing/` recovery; delegates dispatch to `SlashHandler`; instructs `Esr.Slash.QueueResult` for per-stage file moves |
| `Esr.Admin.Commands.*` | **renamed → `Esr.Commands.*`** | not "admin"-specific; just commands |
| `internal_kinds:` block in slash-routes.yaml | **kept as a separate sub-namespace, NOT merged into `slashes:`** | see "internal_kinds is non-trivial" below — flat collapse changes security surface |
| `py/src/esr/cli/{cap,users,notify,reload,admin}.py` | **deleted** | replaced by Elixir-native escript |
| `py/src/esr/cli/daemon.py` | **kept short-term** | lifecycle is `launchctl`-bound; can later move into the escript but isn't priority |
| `py/src/esr/cli/main.py` | **mostly retained** | review found 31 click commands here, most NOT in slash-routes.yaml: `adapter add/remove/rename/install`, `handler install`, `cmd list/install/show/compile`, `actors`, `deadletter`, `trace`, `debug`, `drain`, `scenario`. These are out of Phase 2 scope; Phase 4 cleanup decides their fate |
| `runtime/scripts/esr` (escript binary) | **new** | single entry; runs as REPL when no args, executes slash when given args |
| `Esr.Cli` (Elixir module set) | **new** | schema-driven argv parsing, slash exec, REPL, lifecycle wrapping |

#### Admin.Dispatcher actually does THREE things

A subagent review of this spec (2026-05-05) caught that the Dispatcher is not a clean duplicate of SlashHandler. It owns:

1. **Dispatch + permission check + invoke**. This part DOES duplicate SlashHandler and migrates there cleanly.
2. **`cleanup_signal` rendezvous for long-running session_end.** `Esr.Admin.Dispatcher` registers a `pending_cleanups :: %{session_id => task_pid}` map and exposes `register_cleanup/2` + `deregister_cleanup/1` callable functions. `Esr.Admin.Commands.Scope.BranchEnd` calls `register_cleanup/2` and blocks on `receive`. `Esr.Entity.Server.build_emit_for_tool("session.signal_cleanup", …)` does a raw `send(Process.whereis(Esr.Admin.Dispatcher), {:cleanup_signal, …})`. **This is a named-process rendezvous**, not just dispatch. It must be relocated, not deleted.
3. **Result-time secret redaction.** Dispatcher writes `[redacted_post_exec]` over `args.{app_secret, secret, token}` before persisting to `completed/<id>.yaml`. Required for ops-history hygiene; deleting it would be a security regression.
4. **Two-phase file moves with stale-processing recovery.** `move_pending_to_processing/1` and `move_processing_to/2` (`completed/` or `failed/`) own the on-disk state machine. The Watcher's boot-time sweep depends on the `processing/` intermediate state being meaningful.

After Phase 2:
- (1) lives in `SlashHandler.dispatch/3`.
- (2) becomes a separate small module — `Esr.Slash.CleanupRendezvous` (~80 LOC) — registered globally; same `register_cleanup/2` / `deregister_cleanup/1` / `signal_cleanup/1` API. `Esr.Entity.Server.build_emit_for_tool` redirects its `send(Process.whereis(...))` target. `BranchEnd` updates its callsite.
- (3) becomes `Esr.Slash.QueueResult.persist/2` — called by `ReplyTarget.QueueFile.respond/2` after the result returns from execute/2. Same redaction rules.
- (4) lives in `Esr.Slash.QueueResult` too — the Watcher reads pending, calls `QueueResult.start_processing/1` (move file to processing/), invokes SlashHandler, and on response calls `QueueResult.finish/2` (move to completed/ or failed/).

This means PR-2.3 in the original draft splits in two:
- PR-2.3a: Create `Esr.Slash.CleanupRendezvous` + `Esr.Slash.QueueResult`. Update `BranchEnd` and `Server.build_emit_for_tool` to use them. Dispatcher still exists; new modules are parallel paths.
- PR-2.3b: Delete `Esr.Admin.Dispatcher`. Watcher rewritten to call SlashHandler + QueueResult.

The original PR-2.3 was not independently green — review identified 10+ test files that `Process.whereis(Esr.Admin.Dispatcher)` and assert it's alive. The split keeps PR-2.3a green (dispatcher untouched) and PR-2.3b green (tests updated alongside the deletion).

#### `internal_kinds:` is non-trivial

The original draft proposed deleting the `internal_kinds:` block from slash-routes.yaml and migrating its 9 entries into `slashes:`. Review caught two problems:

1. **Loader logic difference**: `Esr.Resource.SlashRoute.FileLoader` validates the two blocks as different map shapes. A flat collapse requires real loader changes.
2. **Security surface change**: Several `internal_kinds:` entries (`grant`, `revoke`) are operator-only by design. Today they're file-queue-only — operators run them via `esr admin submit grant ...`. Moving them to `slashes:` makes them slash-text-callable from any chat with `cap.manage` permission. **An operator who has `cap.manage` capability can grant themselves more capabilities by typing into chat.** Today's privilege boundary (cap.manage AND access to admin_queue/pending file write) collapses to just (cap.manage).

Decision: KEEP `internal_kinds:` as a separate sub-namespace. The schema dump endpoint (`PR-2.1`) emits `slashes:` and `internal_kinds:` as separate JSON sections. `esr exec` can call kinds in either section (provided the operator has the cap), but only `slashes:` are slash-callable from chat. Schema-driven CLI/REPL autocomplete shows both, distinguished by a `internal: true` flag.

### `reply_to` abstraction

Today `SlashHandler.dispatch/3` takes a `reply_to :: pid()` and `send/2`s the result. Phase 2 broadens this to a behaviour:

```elixir
defmodule Esr.Slash.ReplyTarget do
  @callback respond(target :: term(), result :: map()) :: :ok | {:error, term()}
end
```

Implementations:

- `Esr.Slash.ReplyTarget.ChatPid` — `send(pid, {:reply, text, ref})`. Chat inbound case.
- `Esr.Slash.ReplyTarget.QueueFile` — write yaml to `admin_queue/completed/<id>.yaml`. Admin queue case.
- `Esr.Slash.ReplyTarget.IO` — print to stdout / format JSON. CLI escript case (one-shot).
- `Esr.Slash.ReplyTarget.WS` — push frame on a Phoenix.Channel socket. REPL case (interactive).

`SlashHandler.dispatch/3`'s third argument changes from a bare pid to a `{module, target}` tuple. The chat / queue paths update to wrap their existing pids/paths in these structs. Backwards-compat shim accepts plain pids during the transition.

### Schema dump endpoint

```
GET /admin/slash_schema.json    → public schema (kinds, args, descriptions, categories)
GET /admin/slash_schema.json?include_internal=1 → adds permissions, command_module
```

Powers:
- escript: reads at startup (cached locally for offline use), generates dynamic CLI subcommands.
- REPL: same source for autocomplete tree.
- Doc generation: replaces the existing `gen-docs.sh` slash extraction logic.

JSON shape mirrors the in-memory registry. New module: `Esr.Resource.SlashRoute.Registry.dump_json/1` (mirrors the existing `Permission.Registry.dump_json/1`).

### CLI escript shape

```
$ esr                               → enter REPL
$ esr exec "/foo bar=baz"           → one-shot slash exec
$ esr exec foo --bar=baz            → equivalent (argv translates to slash text)
$ esr daemon {start,stop,restart,status,doctor}  → lifecycle (launchctl wrapper)
$ esr help [kind]                   → schema dump pretty-print
$ esr describe-slashes [--json]     → schema dump (machine-readable)
```

Argv translation: `esr exec foo --bar=baz arg1` ⇒ slash_text `"/foo bar=baz arg1"`. The escript looks up `foo` in the cached schema to get the canonical argname/positional-args mapping, formats the slash text, and submits.

`esr exec` blocking model: by default writes to admin_queue/pending and polls completed/ for the response yaml (current behaviour). With `--no-wait`, exits immediately after submission. With `--http` (post-Phase-3 channel), uses HTTP `POST /admin/exec` for synchronous response.

### REPL shape

```
$ esr
ESR REPL — connected to esrd-dev (port 4001) — principal linyilun
> /help                              ← autocomplete: tab-completes / + cmd names + arg names
> /plugin list
  installed plugins:
    - bare_component v0.0.1 [enabled]
    ...
> /scope new workspace=esr-dev name=...
  ...
> ^D                                 ← clean exit
```

Implementation: Elixir-native using `IO.gets/1` + ANSI escape codes for autocomplete. Erlang shell's readline-style line editing is sufficient; no need for prompt_toolkit. If escript constraints make this hard, fall back to a managed `port` to a small `linenoise`-like helper.

### Lifecycle commands

`esr daemon start/stop/restart/status/doctor` wrap `launchctl` (existing Python uses subprocess.run for this). Elixir uses `System.cmd("launchctl", [...])`. ~80 LOC.

`doctor` runs the existing `Esr.Admin.Commands.Doctor` module (which in Phase 2 is renamed `Esr.Commands.Doctor`); no change to the doctor logic itself, just the invocation path.

---

## 三、Migration order (PR sequence) / 迁移顺序（PR 序列）

> **中文要点**:
> 10 个独立可合并的 PR：PR-2.0 删 voice → PR-2.1 schema dump endpoint → PR-2.2 ReplyTarget behaviour → PR-2.3a 新模块 `CleanupRendezvous` + `QueueResult`（Dispatcher 仍存在，并行路径）→ PR-2.3b 删 Dispatcher，watcher 重写 → PR-2.4 重命名 `Esr.Admin.Commands.*` → `Esr.Commands.*` → PR-2.5 escript 骨架 → PR-2.6 daemon lifecycle → PR-2.7 e2e 脚本逐一迁移（**不是 sed 而是手工语义重映射**，约 22 个调用点）→ PR-2.8 REPL → PR-2.9 删 Python CLI 子集（约 1100 LOC，不是 2200 — review 修正）。
>
> **PR-2.3 必须拆 a/b**：原方案 PR-2.3 不能独立 green，因为 10+ 测试文件 `Process.whereis(Esr.Admin.Dispatcher)` 引用它。a 引入新模块（与旧并行），b 删旧模块（同步更新测试）。

Each PR is independently mergeable. dev → main promotion happens after the chain.

| PR | Scope | Test gate |
|---|---|---|
| **PR-2.0** | Voice plugin deletion (we never used voice). Delete `runtime/lib/esr/entity/voice_*.ex`, `py/src/voice_*` and `py/src/_voice_common`, voice tests, `pools.yaml`, `bootstrap_voice_pools/1`, voice agents in `agents.yaml`. | unit suite green |
| **PR-2.1** | Add `Esr.Resource.SlashRoute.Registry.dump_json/1` + `GET /admin/slash_schema.json` route, emitting `slashes:` and `internal_kinds:` as separate sections. Plus `?include_internal=1` for permission strings. No behaviour change. | new endpoint test + manual curl |
| **PR-2.2** | Introduce `Esr.Slash.ReplyTarget` behaviour + `ChatPid` + `QueueFile` + `IO` + `WS` impls. `QueueFile`'s `respond/2` is **multi-phase** (`on_accept` / `on_complete` / `on_failed`) so the file state machine is preserved. `SlashHandler.dispatch/3` accepts `{mod, target}` reply tuples; backwards-compat for plain pids. | existing slash + queue tests pass unchanged |
| **PR-2.3a** | Create `Esr.Slash.CleanupRendezvous` (`register_cleanup/2`, `deregister_cleanup/1`, `signal_cleanup/1`) and `Esr.Slash.QueueResult` (`start_processing/1`, `finish/2` with secret redaction). Update `Esr.Admin.Commands.Scope.BranchEnd` and `Esr.Entity.Server.build_emit_for_tool("session.signal_cleanup", _)` to use the new modules. **Dispatcher still exists** — new modules are parallel paths. | scenario 01/07 green; cleanup-signal e2e green; new unit tests for the two modules |
| **PR-2.3b** | Delete `Esr.Admin.Dispatcher`. `Admin.CommandQueue.Watcher` rewritten to call `SlashHandler.dispatch/3` with a `QueueFile` reply target; file moves go through `Esr.Slash.QueueResult`. Update all 10+ test files that `Process.whereis(Esr.Admin.Dispatcher)` to target the new modules. | full unit suite + scenario 01/07/08/11 |
| **PR-2.4** | Rename `Esr.Admin.Commands.*` → `Esr.Commands.*` (git mv + module-name update; alias-collapse safe per R3v1 lessons because module-rename is namespace-tier — use explicit `alias` at every callsite, not collapsed shorthands). `internal_kinds:` block stays — see "internal_kinds is non-trivial" above. | `mix compile --warnings-as-errors` + scenario 01/07/08/11 |
| **PR-2.5** | New `runtime/scripts/esr` escript built via `mix escript.build`: `Esr.Cli.Main.main/1`. Implements `esr exec /<slash text>`, `esr help`, `esr describe-slashes`, plus the `esr admin submit <kind>` and `esr notify` aliases retained as first-class kind-direct paths (not just slash translation — see PR-2.7 risks). ~400 LOC. | escript build + smoke `esr exec /help` + alias compatibility tests |
| **PR-2.6** | `esr daemon` lifecycle (launchctl wrapper). Initially still in Python (`cli/daemon.py` survives) — Elixir port deferred to Phase 4 cleanup. | manual smoke + scenario 01 |
| **PR-2.7** | Convert e2e scripts to use the new escript. **NOT a sed sweep**: per-scenario hand-edit because old `--arg session_id=X` doesn't map to slash schema's `name=X` (different arg names; semantic re-mapping required). PR-2.5 retains `esr admin submit <kind> --arg K=V` as a first-class path so the changes are mostly the `uv run --project py` prefix removal. ~22 call sites across `tests/e2e/scenarios/*.sh` + `common.sh`. | e2e 01/07/08/11 green via new CLI |
| **PR-2.8** | REPL implementation. ~200 LOC. | REPL smoke (spawn cc, enter REPL, /help, exit) |
| **PR-2.9** | **Delete `py/src/esr/cli/{cap,users,notify,reload,admin}.py`** + uv pyproject.toml entry-point removal. ~1100 LOC delete (review measured: not 2200 — `main.py` and `daemon.py` stay short-term per Phase 2 vs Phase 4 split). Verify no caller left. | full suite + e2e + grep -r in repo for old call patterns |

PR-2.0 is independent (delete voice). The rest must run in order; PR-2.5 onward depends on PR-2.3b + PR-2.4 having landed.

### Realistic LOC delta

Subagent review measured the actual Python CLI: 3083 LOC across 10 files, of which only `cap.py` (229) + `users.py` (403) + `notify.py` (91) + `reload.py` (78) + `admin.py` (90) = **891 LOC** are clean Phase 2 deletes. `main.py` (1618 LOC, 31 click commands) and `daemon.py` (237 LOC) carry features mostly NOT in `slash-routes.yaml` (adapter management, scenario runner, deadletter, trace, debug commands) — those are out of Phase 2 scope.

Plus: ~200 LOC in `Esr.Admin.Dispatcher` (split, not all deleted — ~80 LOC moves to `CleanupRendezvous`, ~50 LOC to `QueueResult`, leaves ~70 LOC truly deleted) + ~50 LOC of duplicated Watcher logic.

New code: ~400 LOC `Esr.Cli` escript + ~200 LOC REPL + ~80 LOC `CleanupRendezvous` + ~120 LOC `QueueResult` + ~100 LOC `ReplyTarget` impls = ~900 LOC.

**Net delete: ~891 + 120 - 900 ≈ 100 LOC** (and a much cleaner architecture; the win is in single-source-of-truth, not LOC count). Earlier "~2500+ LOC delete" claim was wrong — Phase 2's value is the contract unification, not raw delete count.

---

## 四、Risks & mitigations / 风险与缓解

> **中文要点**:
> 关键风险:
> - **YAML 注释保留**：`esr cap grant` 当前用 ruamel 保留 capabilities.yaml 的 11 行说明性注释 header；Elixir yaml_elixir 不保留。**对策**: 头部模板重新发出（kubectl 用同样模式）。
> - **escript 启动开销**：约 200-500ms 冷启动；shell 循环里跑 `esr exec` 会有感。建议 REPL 作为默认操作员入口避免冷启动反复。
> - **REPL line editing**: edlin vs rlwrap，先尝试 edlin 风格，必要时回退 rlwrap。
> - **operator 肌肉记忆**：旧命令名（`esr cap list`, `esr admin submit foo`, `esr notify`）保留为 alias，零关学习。
> - **预编译脚本兼容**：现有 `esr admin submit foo --arg bar=baz` 通过 escript 内 alias 直通，无需脚本改动。
> - **回滚计划**：每个 PR 独立 git revert；只有 PR-2.9（Python 删除）需要走 git restore，标准流程。

### YAML comment preservation

`esr cap grant` currently uses Python's `ruamel.yaml` to round-trip preserve comments in `capabilities.yaml`. Elixir's `yaml_elixir` does NOT preserve comments. Subagent review caught that `etc/capabilities.yaml.example` ships an 11-line comment header documenting grant format — operators copy this file to `~/.esrd/<env>/capabilities.yaml`, and every `esr cap grant` would silently strip it. That's worse than "informational".

**Strategy** (chosen after review):

1. **Header re-emission**: `Esr.Slash.QueueResult.persist_yaml/2` and `Esr.Commands.Cap.Grant` keep a hardcoded `@header` constant matching `etc/capabilities.yaml.example`'s comment block. On every write, the writer re-emits the header before the parsed-then-serialized body. Operators editing the body don't lose the header; operators editing the header... well, they shouldn't (the header is documentation, not config).
2. **Schema migration once**: PR-2.4 ships a one-time pass that re-emits all yaml files under `~/.esrd/<env>/` with the canonical headers, before any further writes happen. Lossless transition.
3. **Document in PR-2.4 release notes**: "yaml comment preservation now uses re-emitted headers; if you've added custom comments, copy them to your operator notes — they will be lost on the next write."

This is option (a) "header re-emission" from the review's recommendation list. Acceptable; common pattern (kubectl uses it).

### escript distribution

escript packages BEAM bytecode but needs Erlang installed at runtime. **Already present** (esrd's BEAM is the same install). Zero new dep. We commit the built escript to git? Or build at install time? Choice: build at install time via `mix escript.build` invoked by `scripts/launchd/install.sh`. Keeps git clean.

### REPL interactivity

`IO.gets/1` works but lacks tab-completion. Erlang's `:edlin` is callable but a bit of work. If autocomplete proves messy in pure Elixir, fallback: use `rlwrap` as a wrapper script:
```bash
exec rlwrap -C esr -f <(esr describe-slashes --rlwrap-completion) ...
```
`rlwrap` is widely installed; falls back gracefully. We start with `:edlin`-style and only adopt `rlwrap` if needed.

### Operator muscle memory

Old commands keep their names (`esr cap list`, `esr admin submit foo`, `esr notify ...`) — these are aliases dispatched through `esr exec` internally. No relearn. Bash completion regenerated from schema dump.

### Backwards-compat for pre-built scripts

Existing scripts that call `esr admin submit foo --arg bar=baz` continue to work — `esr admin` is a thin dispatcher in the new escript that just calls `esr exec foo --bar=baz`. Same applies to `esr notify` (alias for `esr exec notify ...`).

### Rollback plan

Each PR independently rollback-able via `git revert` until PR-2.9 (Python deletion) — that one needs a "restore from prior commit" if rolled back, which is normal git workflow.

---

## 五、Plugin contract for Phase 3 / 给第三阶段提供的 plugin 契约

> **中文要点**:
> 第三阶段的 plugins 通过 3 个机制消费第二阶段的契约：(1) plugin manifest 的 `slash_routes:` 片段被 FragmentMerger 合进 `SlashRoute.Registry`；(2) plugin 的 `Esr.Commands.<Plugin>.<Cmd>` 模块被 Loader 加进 dispatch 表；(3) 因为 schema 是单一来源，plugin 的命令**自动**出现在 `esr help` / `esr describe-slashes --json` / REPL 自动补全 / `esr exec /<plugin-cmd>`，**零额外代码**。这就是为什么"plugin → 自动 slash + CLI + REPL"不是 over-engineering — 就是 schema 单一来源的自然推论。

Phase 3 plugins consume the Phase 2 contract by:

1. Plugin manifest's `slash_routes:` fragment is merged into `Esr.Resource.SlashRoute.Registry` at boot — same as Phase 1 already does.
2. Plugin's `Esr.Commands.<Plugin>.<Cmd>` modules are loaded into the dispatch table at boot — same as Phase 1 already does.
3. **No additional plugin changes** for Phase 2's CLI/REPL surface to expose them. Plugin commands appear in `esr help`, `esr describe-slashes --json`, REPL autocomplete, and `esr exec /<plugin-cmd>` automatically because the schema is the source of truth.

This is what makes "plugin → automatic CLI + REPL + slash" not over-kill: the schema drives all four surfaces; plugins contribute schema fragments; everything follows.

---

## 六、Out of scope / 不在本阶段范围

> **中文要点**: plugin 物理迁移（第三阶段）/ Channel 抽象（第三阶段 PR-3.7）/ 鉴权模型变更（独立 brainstorm）/ HTTP 同步 slash exec（第三阶段 channel 落地后再考虑）/ 发行打包 mix release vs escript（第四阶段清理时决定）— 都不在第二阶段范围。

Listed so reviewers can confirm the scope:

- **Plugin physical migration** (Phase 3, separate spec).
- **Channel abstraction** (Phase 3 PR-3.1; `docs/issues/02-cc-mcp-decouple-from-claude.md`).
- **Auth model rework** (separate brainstorm; `ESR_OPERATOR_PRINCIPAL_ID` env stays).
- **HTTP API for synchronous slash exec** (`POST /admin/exec` with JSON body) — touched on but deferred until Phase 3 channel abstraction lands; admin_queue file path remains the v1 transport.
- **Distribution (mix release vs escript)** — escript is the v1 choice; mix release is a Phase 4 cleanup option.

---

## 七、Open questions / 待决问题

> **中文要点**: REPL line editing (edlin/rlwrap) 实施时定 / `esr admin submit` alias 永久保留还是后期 deprecate（建议永久）/ schema dump endpoint 鉴权（include_internal=1 需 token）/ 文件状态机 ownership（已在前文解决：归 `Esr.Slash.QueueResult`）。

1. **REPL line editing**: edlin vs rlwrap — start with edlin, fall back to rlwrap if friction high. Decision deferred to PR-2.8 implementation.
2. **`esr admin submit` alias retention**: keep forever for backwards-compat OR deprecate after 1 release? Recommend keep forever — it's free and operators have it in scripts/wikis.
3. **Schema dump auth**: should `/admin/slash_schema.json` be open or require an auth token? Recommend public for `?include_internal=0` (no permission strings exposed), require token for `?include_internal=1`. Defer to PR-2.1.
4. **File state machine ownership**: subagent review caught that today's watcher does NOT own file moves — `Esr.Admin.Dispatcher` does. After Phase 2's split, `Esr.Slash.QueueResult` owns `start_processing/1` (pending → processing) and `finish/2` (processing → completed/failed) including the secret redaction; the Watcher's main loop drives the state machine via these calls. Boot-time stale-`processing/` recovery moves to `QueueResult.recover_stale/1`.
