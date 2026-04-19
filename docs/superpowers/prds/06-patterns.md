# PRD 06 — Patterns (feishu-app-session + feishu-thread-session)

**Spec reference:** §6 Command (EDSL, compilation, YAML artifact), §6.2 worked example
**Glossary:** `docs/superpowers/glossary.md`
**E2E tracks:** A (install), B (spawn + InvokeCommand), H (correctness)
**Plan phase:** Phase 6

---

## Goal

Ship the two command patterns the v0.1 E2E requires: the singleton `feishu-app-session` bound to one Feishu app, and the per-thread `feishu-thread-session` spawned on demand. Both authored via the Python EDSL (PRD 02 §6.9), compiled to canonical YAML at `patterns/.compiled/`.

## Non-goals

- The reverse-path CLI pattern (`cc-to-feishu`) — reverse path is handled by the two existing patterns' handlers emitting opposite-direction Route / Emit actions, not by a separate command
- `compose.serial` showcase (available but not needed for these two patterns)
- Parallel / feedback composition (v0.2+)

## Functional Requirements

### F01 — `feishu-app-session` pattern
`patterns/feishu-app-session.py` registers a `@command("feishu-app-session")` that declares exactly one node:
```python
node(
    id="feishu-app:{{app_id}}",
    actor_type="feishu_app_proxy",
    adapter="feishu-{{instance_name}}",
    handler="feishu_app.on_msg",
    params={"app_id": "{{app_id}}"},
)
```
Parameters: `app_id` (required), `instance_name` (required). **Unit test:** `patterns/tests/test_feishu_app_session.py` — compile_topology returns a Topology with 1 node, 0 edges, 2 params.

### F02 — `feishu-thread-session` pattern
`patterns/feishu-thread-session.py` registers a `@command("feishu-thread-session")` that declares three nodes with `depends_on`. The `tmux` node carries an `init_directive` that creates the tmux session before any dependent (cc) spawns, per spec §6.3 / PRD 01 F13b:

```python
thread = node(
    id="thread:{{thread_id}}",
    actor_type="feishu_thread_proxy",
    handler="feishu_thread.on_msg",
    params={"thread_id": "{{thread_id}}"},
)
tmux = node(
    id="tmux:{{thread_id}}",
    actor_type="tmux_proxy",
    adapter="cc_tmux",
    handler="tmux_proxy.on_msg",
    depends_on=[thread],
    init_directive={
        "action": "new_session",
        "args": {
            "session_name": "{{thread_id}}",
            "start_cmd": "./e2e-cc.sh",
        },
    },
)
cc = node(
    id="cc:{{thread_id}}",
    actor_type="cc_proxy",
    handler="cc_session.on_msg",
    depends_on=[tmux],
)
thread >> tmux >> cc
```
Parameters: `thread_id` (required).

**Why init_directive on the tmux node:** the tmux adapter needs to actually launch a tmux session before it can send keys or capture output. Placing `new_session` on node spawn (via init_directive) means: (a) the tmux session exists exactly once per thread, (b) if it fails to start, the thread's cc actor never spawns and the instantiation rolls back cleanly, and (c) no handler code sees an uninitialised tmux.

**Unit test:** `patterns/tests/test_feishu_thread_session.py`
- 3 nodes, 2 edges, 1 param, `depends_on` DAG correct
- Compiled YAML for tmux node contains `init_directive` block verbatim
- Instantiating with `thread_id="foo"` substitutes `{{thread_id}}` → `foo` in `init_directive.args.session_name`

### F03 — Compiled YAML exists
`esr cmd compile feishu-app-session` produces `patterns/.compiled/feishu-app-session.yaml` with schema matching spec §6.3. Same for `feishu-thread-session`. **Unit test:** `patterns/tests/test_compile_yaml.py` — round-trip (compile → YAML → parse → compare to compile_topology result).

### F04 — YAML deterministic
Compiling the same pattern twice produces byte-identical YAML (modulo timestamps, but no timestamps are generated). Key ordering sorted. **Unit test:** `patterns/tests/test_compile_yaml.py` — two compiles, same bytes.

### F05 — Dead-node elimination
If a pattern declares a node but never references it in edges or ports, the compiler removes it. **Unit test:** `patterns/tests/test_optimizer_dead.py` — pattern with an orphan → compiled has no orphan.

### F06 — CSE on compose
When `compose.serial(A, B)` is used and A's output port and B's input port have the same name and type, the merged node appears exactly once in the compiled output (spec §6.7). **Unit test:** `patterns/tests/test_optimizer_cse.py` — a contrived composed pattern → one merged node.

### F07 — Depends_on cycle rejected at compile time
A pattern with a cycle (A depends on B, B depends on A) fails `compile_topology` with `ValueError("depends_on cycle")`. **Unit test:** `patterns/tests/test_cycle_rejected.py`.

### F08 — Dependency resolution
`esr cmd install ./patterns/feishu-thread-session.py` fails if `cc_tmux` adapter or `feishu_thread.on_msg`, `tmux_proxy.on_msg`, `cc_session.on_msg` handlers are not installed, with a clear error message listing each missing dep (PRD 07 F11). **Unit test:** `patterns/tests/test_install_resolution.py` — missing dep → install fails with expected message.

### F09 — Install writes compiled YAML
On successful install, the `.compiled/<name>.yaml` is written (or overwritten). **Unit test:** `patterns/tests/test_install_writes_compiled.py`.

### F10 — Inspection via `esr cmd show`
`esr cmd show feishu-thread-session` pretty-prints the compiled topology with node IDs, edges, and `depends_on` DAG visualisation (ASCII art). **Unit test:** `patterns/tests/test_show.py` — output contains all node IDs.

### F11 — Param template lint
If a pattern references `{{foo}}` but doesn't register `foo` as a param (via port.input or explicit param declaration), compile errors. Reverse also errors (declared param never referenced). **Unit test:** `patterns/tests/test_param_lint.py`.

## Non-functional Requirements

- Compile time for a single pattern < 100 ms
- Compiled YAML < 10 KB per pattern (feishu-thread-session is our largest in v0.1 and has 3 nodes)
- EDSL ergonomics: a reviewer reading the `.py` source can guess the compiled YAML structure without running the compiler

## Dependencies

- PRD 02 (SDK) for `@command`, `node`, `port`, `compose`, `compile_topology`, `compile_to_yaml`
- PRD 04 (adapters): `feishu` and `cc_tmux` must be installed to satisfy dependency resolution
- PRD 05 (handlers): all four handlers must be installed

## Unit-test matrix

| FR | Test file | Test name |
|---|---|---|
| F01 | `patterns/tests/test_feishu_app_session.py` | one-node compile |
| F02 | `patterns/tests/test_feishu_thread_session.py` | 3-node DAG compile |
| F03 | `patterns/tests/test_compile_yaml.py` | round-trip |
| F04 | same | byte-deterministic |
| F05 | `patterns/tests/test_optimizer_dead.py` | orphan removed |
| F06 | `patterns/tests/test_optimizer_cse.py` | merged node |
| F07 | `patterns/tests/test_cycle_rejected.py` | cycle → error |
| F08 | `patterns/tests/test_install_resolution.py` | missing dep → error |
| F09 | `patterns/tests/test_install_writes_compiled.py` | `.compiled/*.yaml` written |
| F10 | `patterns/tests/test_show.py` | pretty print |
| F11 | `patterns/tests/test_param_lint.py` | lint errors |

## Acceptance

- [ ] All 11 FRs have passing unit tests
- [ ] Both patterns install via `esr cmd install` after their deps are installed
- [ ] `esr cmd list` shows `feishu-app-session`, `feishu-thread-session`
- [ ] `esr cmd show feishu-thread-session` renders the 3-node DAG
- [ ] Integration: E2E Track B spawns instances of both patterns

---

*End of PRD 06.*
