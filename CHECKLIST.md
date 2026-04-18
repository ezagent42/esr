# ESR Project Checklist

Tracks the original 6-subtask plan agreed during the brainstorming session on 2026-04-18.
Keep this file up to date — its purpose is to survive context windows and remind us of
what we originally set out to do.

## Status

| # | Subtask | Status | Artifact |
|---|---------|--------|----------|
| 1 | 建立 esr/ 项目文件结构（根据 ESR 定义） | in design | Spec will define |
| 2 | 讨论完整的 E2E 测试流程（feishu-to-cc + 反向 + 多 session） | in design | Spec will define |
| 3 | 根据最终 E2E 分解为 PRD，并定义对应的 unit test | pending | Writing-plans phase |
| 4 | 从 cc-openclaw 迁对应代码 | pending | Per-PRD tasks |
| 5 | 迭代改代码 → 全部 unit test 通过 | pending | Implementation |
| 6 | 迭代改代码 → E2E 通过 | pending | Final gate |

## Scope boundary (v0.1)

**In scope:**
- 4-layer architecture: Elixir runtime / Python handler / Python adapter / Python command
- Handler = pure function (purity enforced via test, not runtime sandbox)
- Adapter = pure factory producing I/O-capable inner fn
- Command = typed open graph pattern compiler; serial composition only
- Python EDSL as primary authoring surface; YAML as canonical artifact
- Compile-time optimization: dead-node elimination + CSE only
- E2E validation: platform capabilities (registration, scheduling, observability, operation, debugging) — not just a business demo

**Out of scope (deferred):**
- Parallel / feedback pattern composition
- Advanced optimization passes (operator fusion, placement, batching)
- Socialware packaging, governance workflow, external interface exposure
- Multi-node BEAM cluster (single node first)
- Natural-language → YAML LLM front-end
- Contract verification / verifier infrastructure (borrow from esrd spec later)

## Original request (paraphrase, 2026-04-18)

> Extract generic functionality from cc-openclaw into a new esr/ project implementing ESR.
> Layer thinking:
> 1. Actor Model Runtime — replace with Elixir
> 2. Message Handler — exposed from Elixir, processes messages
> 3. Adapter — Python side, connects external environments to Elixir
> 4. Command — business topology in Python
>
> Example CLI:
> - `esr adapter add feishu app-id app-secret`
> - `esr adapter add claude-code start-cmd.sh`
> - `esr cmd add feishu-to-core` / `esr cmd add core-to-cc`
> - `esr cmd add feishu-to-cc` (compose)
> - `esr cmd run feishu-to-cc {src, trg, payload}`
> - `esr cmd list`

## Related artifacts

- Design spec (to be written): `docs/superpowers/specs/2026-04-18-esr-extraction-design.md`
- ESR v0.3 reference docs: `docs/design/`
- Brainstorm transcript: not persisted — distilled decisions go into spec

## Decision log (during brainstorming)

| Decision | Rationale |
|---|---|
| Handler is pure Python, not Elixir | AI writes Python better; purity enforced by test |
| Sandbox dropped in favour of CI lint + frozen-state fixture | Sandbox was over-engineering |
| Adapter = pure factory + impure inner fn | Clean FP separation; factory testable |
| Command = typed-open-graph compiler | Aligns with KPN / String Diagrams prior art |
| Serial composition only in v0.1 | YAGNI |
| Python EDSL primary authoring | `>>` operator, cdk8s-style |
| YAML artifact as source-of-truth | Diff-able, audit-able, Elixir-consumed |
| Optimization = dead-elim + CSE only | Semantics-preserving, correctness-adjacent |
| E2E validates platform, not just business | Registration, scheduling, observability, ops, debug |
| 3-layer management surfaces: `esrd` + `esr` + BEAM REPL | Sysadmin vs workflow vs emergency; from esrd spec §2.6 |
| Adapters flat; nesting via topology `depends_on` | Stacking explodes complexity; topology already expresses intent |
| Unified `esr://` URI for all addressable resources | Needed for cross-boundary; consistent with Reposition doc |
| Pattern/adapter/handler install = `esr <type> install <source>` | Mirrors `pip install`; name-based resolution |
| One esrd = one org, can host many adapter instances | Second Feishu app = second adapter instance, not second org |
| Dogfooding: two esrd instances (prod + dev) | Prod stays up while dev is restarted freely |
| Latency monitored, not optimised in v0.1 | Sanity thresholds only; instrument day one |
