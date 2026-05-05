# Phase 4 — Cleanup
# 第四阶段 — 清理

**Date / 日期:** 2026-05-05
**Status / 状态:** Draft for user review / 草案，待用户评审。
**Predecessor / 前序:** Phase 2 + Phase 3 must be merged first / 第二、三阶段先合并。
**Successor / 后继:** None — cleanup tail / 收尾，无后继。

> **本规格说明书采用中英双语写作（English + 中文）**: 每个大节先英文叙述，再用中文总结。
>
> **This spec is bilingual (English + Chinese)**: each section presents English text followed by Chinese summary.

---

## 一、Why this phase exists / 为什么需要这个阶段

> **中文要点**:
> 1-3 阶段都倾向"先加新路径再删旧路径"，每个 PR 独立可回滚 — 代价是落地后仓库里残留：(1) `Esr.Application.start/2` 中只为 stub manifest 存在的 fallback registration；(2) 已被 PR-186 in-process 自动确认替代但保留作"冗余安全网"的 bash + websocat helper；(3) Phase 1 stub manifests（voice 已删，feishu/cc 在第三阶段被覆盖）；(4) `Esr.Admin.*` 命名空间（删除 Dispatcher 后只剩 watcher，不值占顶层）；(5) `permissions_registry.json` 跨语言桥（Elixir-native CLI 直接调 registry 后无用）；(6) `main.py` 31 个 click 命令大半不在 slash schema 范围内，第二阶段没动。
>
> 第四阶段把这些一次性收齐删，每步独立、零行为变更（新路径已在 1-3 阶段验证完整覆盖旧路径）。

## 一、Why this phase exists (English elaboration)

Phases 1–3 ship transitional code. By design — they prefer "add new path, then remove old path" over big-bang rewrites, so each PR is independently reviewable, mergeable, and revertable. The cost is that after the dust settles, the repo carries:

- Fallback registrations in `Esr.Application.start/2` that exist only because Phase 1's stub manifests didn't actually own the data.
- The legacy bash + websocat helper for dev-channels confirmation, superseded by Phase 1 PR-186's in-process FCP auto-confirm.
- Stub manifests (the bare voice/feishu/claude_code that Phase 1 PR-180 created) — voice deleted in Phase 2 PR-2.0, feishu/claude_code superseded by Phase 3's full plugin dirs.
- The `Esr.Admin.*` namespace — after Phase 2 deletes Dispatcher and renames Commands, what remains is a few non-admin guards (PendingActionsGuard, CapGuard) that don't justify a top-level namespace.
- Duplicated `permissions_registry.json` JSON dump (created for Python CLI's `cap list`) — once Elixir-native CLI talks directly to the registry, the dump is dead.
- Several Python CLI sub-modules that Phase 2's PR-2.9 didn't touch because they cover features outside the slash schema: `daemon.py`, `main.py`'s 31 commands (adapter management, scenario runner, deadletter, trace, debug). Phase 4 decides each one's fate.
- Old e2e helpers superseded by `tools/esr-debug` (PR-187): `tests/e2e/_helpers/dev_channels_unblock.sh`.

Phase 4's goal is to land all of this as a single clean-up PR series, with no behaviour changes — every removal must be safe by construction (the new path is verified in Phase 1–3 to fully cover the old path).

### Goals

1. After Phase 4, the only Python under `py/src/esr/cli/` (if any survives) is what Phase 4 explicitly decides to keep with documented rationale.
2. `Esr.Application.start/2` is "boots core then asks plugins to register their contributions" with NO plugin-specific knowledge.
3. Stub manifests deleted; only real plugin manifests live under `runtime/lib/esr/plugins/<name>/manifest.yaml`.
4. `Esr.Admin.*` namespace either resolved to its remaining tenants or fully merged elsewhere with no dangling references.
5. `tests/e2e/_helpers/` contains only what's actually used.
6. Documentation reflects Phase-4 reality (no stale references to "feishu plugin coming soon" etc.).

### Non-goals

- New features. Phase 4 is purely about removal + tidy-up.
- Auth model changes (still separate brainstorm).
- Distribution packaging (mix release, etc.) — could be a Phase 5 if the operator team wants it.

---

## 二、What gets cleaned up / 清理对象清单

> **中文要点（7 组清理对象）**:
> A. `Esr.Application.start/2` 中只为 stub manifest 存在的 fallback registration（feishu/cc_mcp Sidecar fallback、`bootstrap_feishu_app_adapters/0`），第三阶段后 plugin manifest 全权接管，删 fallback。
> B. Phase-1 stub manifests — voice 已删，feishu/cc 已被第三阶段覆盖为真 manifest，本阶段只加 CI guard 验证。
> C. `tests/e2e/_helpers/dev_channels_unblock.sh` — PR-186 in-process FCP auto-confirm 已经替代，连续 5 次 scenario 07 通过即可删。
> D. `Esr.Admin.*` 命名空间 — Phase 2 删 Dispatcher + 重命名 Commands 后只剩 `Esr.Admin.CommandQueue.Watcher` 和 `Esr.Admin.Supervisor`，迁到 `Esr.Slash.QueueWatcher` + `Esr.Slash.Supervisor`，命名空间空了即可删。**注意**: PendingActionsGuard 在 EsrWeb，CapGuard 在 Esr.Entity，都不在 Admin namespace（review 修正了原 spec 的错误叙述）。
> E. `permissions_registry.json` 跨语言 dump — Elixir-native CLI 直接调 registry 后，dump 文件无消费者，删除。
> F. Python CLI 残余（`main.py` 的 31 个 click + `daemon.py`）— 第二阶段没动是因为不在 slash schema 范围内；本阶段逐一 port 或删除（约 ~600 LOC Elixir 替换 ~1900 LOC Python，净删 ~1300 LOC）。
> G. Python venv 整体移除 — uv tool install esr 改为 mix escript.install 或类似，operator 重装一次。

### Group A — `Esr.Application.start/2` plugin-specific bootstraps

After Phase 1, `Esr.Application.start/2` registers fallback Sidecar mappings (`feishu → feishu_adapter_runner`, `cc_mcp → cc_adapter_runner`) so existing tests don't break before plugin manifests own these. After Phase 3 lands, the manifests own them. **Delete the fallback** (~6 lines).

`bootstrap_feishu_app_adapters/0` and similar feishu-specific bootstraps in `Esr.Application` and `Esr.Scope.Admin` move into the feishu plugin's startup hook (Phase 3 PR-3.3 does the conceptual move; Phase 4 verifies the old function is dead and deletes it).

`bootstrap_voice_pools/1` is deleted by Phase 2 PR-2.0; Phase 4 just verifies and removes the dead-call site if any survived.

**Test**: scenario 01/07/08/11 still green. `Esr.Application.start/2` must compile and boot with `enabled_plugins: []` cleanly (Phase-1 PR-2.7's e2e 08 already covers this).

### Group B — Phase-1 stub manifests

PR-180 added 3 stub manifests at `runtime/lib/esr/plugins/{voice,feishu,claude_code}/manifest.yaml` that only DECLARED what core contained. After:

- Voice deleted (Phase 2 PR-2.0): the `voice/` directory is already gone.
- Feishu fully extracted (Phase 3 PR-3.3 + PR-3.4): the `feishu/` manifest now points at the real modules in the same dir.
- Claude_code fully extracted (Phase 3 PR-3.6 + PR-3.7 + PR-3.8): the `claude_code/` manifest now points at the real modules in the same dir.

**There's no Phase-4 cleanup work for stub manifests** — Phase 3 already overwrote them with real manifests as part of the move. Phase 4 just verifies the manifests describe real plugin content (CI guard: every `entities:` module declared in a manifest must be loadable; every `python_sidecars:` referenced module must exist on disk).

### Group C — Legacy bash + websocat helpers

`tests/e2e/_helpers/dev_channels_unblock.sh` was kept in scenario 07 as a "redundant safety net" after PR-186's FCP in-process auto-confirm landed (2026-05-04). Verify safety net is unnecessary, then delete:

- Run scenario 07 with the helper line commented out for 5 consecutive runs (current behaviour: passes — verified manually 2026-05-04).
- Delete `dev_channels_unblock.sh` and the `BOOTSTRAP="$(...)/dev_channels_unblock.sh"` line in scenario 07.
- Delete the call site in scenario 07 step 2.

**Test**: scenario 07 green for 5 runs in a row.

### Group D — `Esr.Admin.*` namespace fate

After Phase 2 deletes `Esr.Admin.Dispatcher` and renames `Esr.Admin.Commands.*` → `Esr.Commands.*`, the `Esr.Admin.*` namespace contains only:

- `Esr.Admin.CommandQueue.Watcher` — file watcher; after Phase 2 it's a thin wrapper around SlashHandler. Move to `Esr.Slash.QueueWatcher` (closer to its peers `Esr.Slash.QueueResult` + `Esr.Slash.CleanupRendezvous`).
- `Esr.Admin.Supervisor` — supervisor of the above. Either merge into `Esr.Slash.Supervisor` or just delete and put the watcher under top-level `Esr.Supervisor`'s children list.

After this move, `Esr.Admin.*` has no occupants — the namespace itself is deleted from `mix.exs` lookup paths and any moduledoc references.

`PendingActionsGuard` and `CapGuard` are NOT in `Esr.Admin.*` today (they're under `EsrWeb.PendingActionsGuard` and `Esr.Entity.CapGuard`); review caught the original spec wording was wrong. They stay where they are.

**Test**: full suite green after the rename + supervisor reshape.

### Group E — `permissions_registry.json` cross-language dump

Today `Esr.Resource.Permission.Registry.dump_json/1` writes `~/.esrd/<env>/permissions_registry.json` so the Python `esr cap list` can pretty-print without an RPC. After Phase 2's Elixir-native `esr cap list` calls the registry directly, the JSON dump is unused.

- Verify no caller reads the file (`grep permissions_registry.json runtime/ py/`).
- Delete `dump_json/1` itself + the boot-time call to it in `Esr.Resource.Permission.Bootstrap`.
- Delete the file from any `~/.esrd/<env>/` checked into operator setup notes.

**Test**: `esr cap list` (new Elixir-native) returns the same content; full suite green.

### Group F — Python CLI residues outside Phase 2's PR-2.9

`py/src/esr/cli/main.py` (1618 LOC, 31 click commands) and `daemon.py` (237 LOC) survive Phase 2 because they cover features outside the slash schema. Phase 4 categorizes each surviving command:

| command | category | Phase 4 action |
|---|---|---|
| `esr daemon {start,stop,status,restart,doctor}` | lifecycle (launchctl) | port to escript (~80 LOC Elixir replacing 237 Python) |
| `esr use <host:port>` | dev-instance switch | port to escript or shell function (trivial) |
| `esr status` | esrd healthcheck | port to escript via slash route + JSON serialization |
| `esr drain` | maintenance | port to escript via slash route |
| `esr trace` | telemetry | currently calls into BEAM via dist Erlang; could port or could keep as a thin Python shim |
| `esr lint <path>` | yaml lint | port via Elixir slash + yaml parser; or delete entirely (operators rarely use it) |
| `esr scenario run` | e2e runner | this just shells out to `bash tests/e2e/scenarios/...` — convert to a thin shell wrapper in the escript |
| `esr adapters list` | adapters table | port via slash route + JSON |
| `esr adapter {add,remove,rename,install}` | adapter management | each is admin_queue submission; port to slash + escript |
| `esr handler install` | handler install | admin_queue submission |
| `esr cmd {list,install,show,compile}` | compiled artifact mgmt | port via slash routes |
| `esr actors list` | actor inventory | port to escript via slash route |
| `esr deadletter` | dead letter inspection | port |
| `esr debug` | debug commands | already largely covered by `tools/esr-debug` (PR-187) — delete the click `esr debug` group |

Phase 4 estimate: ~600 LOC Elixir replacing ~1900 LOC Python. Net delete ~1300 LOC.

**Test**: full suite green; e2e scripts migrated; no `uv run` entry point left for esr CLI.

### Group G — Python venv removal

Once Phase 4 Group F finishes, the only `py/src/esr/` survival is `runtime_bridge.py` (esrd lifecycle) and `paths.py` (path constants), if even those — both can be inline-collapsed into the escript or just deleted. After:

- `py/pyproject.toml` loses the `esr` console_scripts entry-point.
- `py/src/esr/cli/` deleted entirely.
- Operators who installed via `uv tool install esr` need to re-install pointing at the new Elixir escript binary.

**Test**: `which esr` resolves to the escript binary; `esr` runs successfully.

---

## 三、Migration order / 迁移顺序

> **中文要点**: 7 个独立 PR — PR-4.1 (A 组) → PR-4.2 (C 组) → PR-4.3 (D 组) → PR-4.4 (E 组) → PR-4.5 (B 组 CI guard) → PR-4.6 (F 组按 click 子命令分批) → PR-4.7 (G 组最终 Python 删除)。**第四阶段比 1-3 阶段安全**因为只是删除，每步 e2e 全套验证。

Phase 4 is fundamentally lower-risk than Phases 1–3 (it's just removal). Each PR can be small and independent.

| PR | Group | Scope | Test gate |
|---|---|---|---|
| **PR-4.1** | A | Delete `Esr.Application.start/2` plugin-specific bootstraps verified-superseded by manifests. | scenario 01/07/08/11 green |
| **PR-4.2** | C | Delete `tests/e2e/_helpers/dev_channels_unblock.sh` + scenario-07 call site. | scenario 07 green ×5 runs |
| **PR-4.3** | D | Move `Esr.Admin.CommandQueue.Watcher` → `Esr.Slash.QueueWatcher`; reshape supervision tree; delete empty `Esr.Admin.*` namespace. | full suite |
| **PR-4.4** | E | Delete `permissions_registry.json` dump + Python `cap list`'s file-reader codepath (Phase 2 already replaced the consumer). | scenario 01/07/08/11 + `esr cap list` smoke |
| **PR-4.5** | B | CI guard verifying every plugin manifest's `entities:` and `python_sidecars:` are real. | new gate test |
| **PR-4.6** | F | Per-command port: each `main.py` click subcommand gets ported or deleted in its own commit. ~14 sub-PRs nested or grouped by category. | full suite + e2e per group |
| **PR-4.7** | G | Final removal: `py/pyproject.toml` entry-point, `py/src/esr/cli/`, uv tool install instructions. Operators re-install. | manual operator validation |

Dependencies: PR-4.1 → PR-4.5 (verify-then-stricten); PR-4.6 → PR-4.7 (port-then-delete); others independent.

---

## 四、Risks & mitigations / 风险与缓解

> **中文要点**:
> - **死代码其实活着**: grep 可能漏掉 string interpolation / Code.eval / 动态 atom — 每个删除 PR 全套 e2e 验证；e2e 失败暴露隐藏调用者。
> - **Operator 重装 surprise**: PR-4.7 Group G 改 esr 安装方式 → 一次明确迁移说明 + 弃用提示先在 Python entry-point 打印一个 minor 版本。
> - **测试 fixture 引用已删 helper**: PR-4.2 原子地删 helper + 删 scenario-07 source 行；CI 跑 scenario 07 验证。
> - **`Esr.Admin.*` 重命名打破 supervisor child specs**: PR-4.3 同一 diff 内做 Application.start/2 child list 编辑 + 重命名。
> - **文档腐烂**: PR-4.3 grep `Esr.Admin\.` 在 docs/、docs/notes/、docs/operations/ 里逐一更新或删除。

### "Dead code" turns out alive

A grep can miss callers (string interpolation, Code.eval, dynamic atom names). Mitigation: every "delete X" PR runs full suite + 4 e2e scenarios. If a hidden caller exists, the e2e fails and we surface it.

### Operator surprise on `esr` re-install

Phase 4 Group G changes how operators install `esr`. Mitigation: ship a clear migration note in PR-4.7's commit message; pin a deprecation notice in `py/pyproject.toml`'s `esr` script for one minor version before deleting (i.e., have the Python entry-point print "this is now an Elixir escript; please install via `mix escript.install`" and exit).

### Test fixtures referencing deleted helpers

`scenario 07` sources `dev_channels_unblock.sh` via `BOOTSTRAP="$(...)/_helpers/dev_channels_unblock.sh"`. If we delete the file but miss the source line, the scenario fails with `command not found`. Mitigation: PR-4.2 deletes both atomically; CI gate runs scenario 07.

### `Esr.Admin.*` rename breaks supervisor child specs

Application.start/2 lists `Esr.Admin.Supervisor` as a child today. Renaming/deleting it breaks boot. Mitigation: PR-4.3 lands the rename + the supervisor list edit in the same diff; can't rename one without the other.

### Documentation rot

Once `Esr.Admin.*` is deleted, every doc that mentions it is wrong. Mitigation: PR-4.3 grep `Esr.Admin\.` in `docs/`, `docs/notes/`, `docs/operations/`, and update or delete each reference.

---

## 五、Out of scope / 不在本阶段范围

> **中文要点**: 发行打包（mix release vs escript，可作为第五阶段）/ 鉴权变更 / 添加新 plugin (telegram, codex 等，本阶段后是常规产品工作) / 重写测试（已在 2-3 阶段完成）。

- Distribution packaging (mix release vs escript) — could be a Phase 5.
- Auth model changes.
- Adding new plugins (tlg / codex / etc.) — that's normal product work after Phase 4 lands.
- Rewriting tests (Phase 4 is purely removal; test rewrites are already in Phase 2/3).

---

## 六、Open questions / 待决问题

> **中文要点**: `tests/e2e/_helpers/` 是否整个目录消失（PR-4.2 实施时定）/ `scenarios/e2e-*.yaml` 引用 Python uv 路径需 PR-4.6 更新（trivial）/ `Esr.Admin.Supervisor` 终归 `Esr.Slash.Supervisor` 还是 `Esr.Supervisor` 直接子（建议 Slash.Supervisor）/ Phase 5 发行打包独立 brainstorm。

1. **`tests/e2e/_helpers/`** — should the directory survive? If only `tools/esr-debug` is used now, the helpers dir might be empty. Decision deferred to PR-4.2 implementation.
2. **`scenarios/e2e-*.yaml` references**: scenario yaml files reference Python `uv run` paths in their setup; PR-4.6 must update those. Easy.
3. **`Esr.Admin.Supervisor` final home**: under `Esr.Slash.Supervisor` or top-level `Esr.Supervisor`? Recommend `Esr.Slash.Supervisor` (the only child after rename is `Esr.Slash.QueueWatcher`).
4. **Phase 5 distribution**: separate brainstorm if the operator team wants `mix release` packaging instead of escript. Not Phase 4.
