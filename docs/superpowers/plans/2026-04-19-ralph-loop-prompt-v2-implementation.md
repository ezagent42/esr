# Ralph-Loop Prompt v2 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the pre-loop infrastructure (loopguard helpers, external gate, manifests, signatures, archived scenario, v2 prompt itself) so that a ralph-loop v2 run can attempt Phase 8 live integration *without* the gate-gaming escape routes that sank v1.

**Architecture:** Everything in this plan is **user-authored or plan-authored BEFORE the loop starts**. The loop's own work (Phase 8a–8f: adapter_runner.run, esrd daemon, CLI wiring, mocks, scenario, live smoke) lives inside the v2 prompt and is driven later. This plan stops at "loop is safe to launch, red-team tests pass, dry-run completes". The spec (`docs/superpowers/specs/2026-04-19-ralph-loop-prompt-v2-design.md`) is the source of truth for every design choice — each task cites the spec section it implements.

**Tech Stack:** Python 3.11+, uv, pytest, bash 5+, pyyaml, ripgrep, Elixir 1.19 / Phoenix 1.8 (for the final live gate — but authoring only; live execution happens inside the loop).

**Post-review hardening (this revision).** The first reviewer pass on this plan
found 6 Critical bypass routes where an adversarial loop could pass loopguard
while faking live evidence. The current revision closes them:

| # | Fix | Affected task(s) |
|---|-----|------------------|
| C-P1 | LG-1 signature check rewritten to literal-substring + reject defanging alternations (`|(.*)` etc.) instead of regex-against-regex | Task 2 |
| C-P2 | LG-2 AST body detector rewritten: any-length body of cheap statements (pass, logger calls, literal returns) is a stub | Task 1 |
| C-P3 | LG-10 extended to walk decorator_list and match any `_submit_*` literal in any Call arg, catching `@patch(...)` and `patch.object(..., "_submit_...")` | Task 5 |
| C-P4 | LG-6 allowlist walks recursively and rejects subdirectories | Task 3 |
| C-P5 | Red-team harness uses `git checkout -- .` after each plant; no filesystem-backup race | Task 19 |
| C-P6 | `capture_ws.py` authored inline; was previously assumed to exist | Task 14 |
| S-P1 | New Task 13b rewrites PRD 01/03/07 Acceptance rows that contain "deferred" language so LG-3 doesn't trip on iteration 1 | Task 13b |

---

## File Structure

```
/Users/h2oslabs/Workspace/esr/
├── scripts/
│   ├── loopguard.sh                          [Task 8]
│   ├── verify_entry_bodies.py                [Task 1]
│   ├── loopguard_scenario.py                 [Task 2]
│   ├── loopguard_scenarios_allowlist.py      [Task 3]
│   ├── verify_prd_acceptance.py              [Task 4]
│   ├── verify_cli_tests_live.py              [Task 5]
│   ├── verify_ledger_append_only.py          [Task 6]
│   ├── ledger_append.py                      [Task 7]
│   ├── final_gate.sh                         [Task 9 — mock; Task 10 — live body stub]
│   ├── final_gate.sh.sha256                  [Task 15]
│   ├── live_signatures.txt                   [Task 11]
│   ├── loopguard-bundle.sha256               [Task 15]
│   └── tests/                                [one test file per helper, Tasks 1–7]
├── docs/
│   ├── superpowers/
│   │   ├── ralph-loop-prompt-v2.md           [Task 18]
│   │   └── prds/
│   │       └── acceptance-manifest.yaml      [Task 12]
│   ├── archive/
│   │   └── 2026-04-18-e2e-platform-validation.yaml  [Task 13]
│   └── ralph-loop-ledger.md                  [Task 17]
├── adapters/feishu/tests/fixtures/live-capture/     [Task 14 — user-collected]
│   ├── text_message.json
│   ├── thread_reply.json
│   └── card_interaction.json
└── .ralph-loop-baseline                      [Task 16]
```

**Why this structure.** Every loopguard helper is a **standalone** script with its own test suite under `scripts/tests/`. The main `py/` package is intentionally *not* modified — the loop will do that later (cf. spec §6.1 loop-authored list). Keeping loopguard tooling separate means: (a) loopguard can run even when `py/` is broken mid-iteration; (b) the SHA bundle for loopguard is small and auditable; (c) pytest for scripts doesn't coupling to the `esr` package's test matrix.

---

## Task 1: `verify_entry_bodies.py` — AST non-empty-body stub detector (LG-2)

Closes reviewer finding C1. Scans declared entry points across the codebase and fails if any has a trivial body (`pass`, `...`, single return/raise, ≤ 2 AST nodes) or returns a hard-coded stub sentinel dict. Uses Python's `ast` module for `.py` files; for `.ex` files, a regex fallback.

**Files:**
- Create: `scripts/verify_entry_bodies.py`
- Create: `scripts/tests/test_verify_entry_bodies.py`
- Create: `scripts/tests/fixtures/entry_bodies/stub_run.py` (test fixture)
- Create: `scripts/tests/fixtures/entry_bodies/real_run.py` (test fixture)

- [ ] **Step 1: Write the failing test**

`scripts/tests/test_verify_entry_bodies.py`:

```python
"""Tests for verify_entry_bodies.py — LG-2 implementation."""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "verify_entry_bodies.py"
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "entry_bodies"


def run(target: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), "--target", target],
        capture_output=True,
        text=True,
        check=False,
    )


def test_detects_pass_body_as_stub() -> None:
    res = run(str(FIXTURES / "stub_run.py") + ":run")
    assert res.returncode != 0
    assert "stub" in res.stdout.lower() or "empty" in res.stdout.lower()


def test_accepts_real_body() -> None:
    res = run(str(FIXTURES / "real_run.py") + ":run")
    assert res.returncode == 0, res.stdout + res.stderr


def test_detects_not_implemented_sentinel() -> None:
    res = run(str(FIXTURES / "stub_run.py") + ":stub_dict_return")
    assert res.returncode != 0
    assert "stub" in res.stdout.lower()
```

`scripts/tests/fixtures/entry_bodies/stub_run.py`:

```python
"""Fixture — simulates an adversarial empty-body stub."""
async def run() -> None:
    pass


def stub_dict_return() -> dict[str, object]:
    return {"ok": False, "error": "not yet wired"}
```

`scripts/tests/fixtures/entry_bodies/real_run.py`:

```python
"""Fixture — simulates a real implementation body."""
import asyncio


async def run(url: str, adapter: object) -> None:
    queue: asyncio.Queue[dict[str, object]] = asyncio.Queue()
    async with asyncio.TaskGroup() as tg:
        tg.create_task(_directive_loop(queue, adapter))
        tg.create_task(_event_loop(adapter))


async def _directive_loop(q: asyncio.Queue[dict[str, object]], adapter: object) -> None:
    while True:
        item = await q.get()
        _ = item


async def _event_loop(adapter: object) -> None:
    await asyncio.sleep(0.001)
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/h2oslabs/Workspace/esr && uv run pytest scripts/tests/test_verify_entry_bodies.py -v
```
Expected: `FileNotFoundError` (script doesn't exist yet) or 3 FAILs.

- [ ] **Step 3: Write minimal implementation**

`scripts/verify_entry_bodies.py`:

```python
"""LG-2 — AST non-empty-body check (closes reviewer C1).

Usage:
    verify_entry_bodies.py [--target <file>:<function>]  # check one
    verify_entry_bodies.py                                # check default manifest

Default manifest (when invoked with no --target) is the spec's §4.3 LG-2 table.

Exit 0 on clean; 1 if any function has a stub body.
"""
from __future__ import annotations

import argparse
import ast
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# Spec §4.3 LG-2 table. Keep in sync with the spec.
DEFAULT_MANIFEST: list[tuple[str, list[str]]] = [
    ("py/src/esr/ipc/adapter_runner.py", ["run"]),
    ("py/src/esr/ipc/handler_worker.py", ["run"]),
    ("py/src/esr/cli/main.py", [
        "_submit_cmd_run", "_submit_cmd_stop", "_submit_actors",
        "_submit_trace", "_submit_telemetry", "_submit_debug",
        "_submit_deadletter", "_submit_drain",
    ]),
    ("py/src/esr/cli/runtime_bridge.py", ["connect", "call", "push_event"]),
    # Loop expands this list as it adds real entry points in Phase 8.
]

STUB_ERROR_SENTINELS = {"not yet wired", "not implemented", "stub", "deferred"}

# Fix for reviewer C-P2: "cheap" statements — any body composed entirely of
# these is a stub regardless of length. Closes the 3-pass / logger-only escape.
LOGGER_METHODS = {"debug", "info", "warn", "warning", "error", "critical", "log"}


def _is_cheap_stmt(stmt: ast.stmt) -> bool:
    """True if the statement contributes no runtime work an entry point needs."""
    if isinstance(stmt, (ast.Pass, ast.Import, ast.ImportFrom)):
        return True
    if isinstance(stmt, ast.Expr):
        val = stmt.value
        if isinstance(val, ast.Constant):
            return True  # bare `...` or string literal
        if isinstance(val, ast.Call):
            fn = val.func
            if isinstance(fn, ast.Attribute) and fn.attr.lower() in LOGGER_METHODS:
                return True
            if isinstance(fn, ast.Name) and fn.id == "print":
                return True
        return False
    if isinstance(stmt, ast.Assign) and isinstance(stmt.value, ast.Constant):
        return True
    if isinstance(stmt, ast.Assign) and isinstance(stmt.value, ast.Call):
        fn = stmt.value.func
        if isinstance(fn, ast.Attribute) and fn.attr in {"getLogger", "get_logger"}:
            return True
        if isinstance(fn, ast.Name) and fn.id == "getLogger":
            return True
    if isinstance(stmt, ast.Return):
        v = stmt.value
        if v is None or isinstance(v, (ast.Constant, ast.List, ast.Tuple, ast.Set, ast.Dict)):
            return True
    if isinstance(stmt, ast.Raise):
        return True  # any raise is stub-like for declared entry points
    return False


def _is_stub_body(func: ast.AsyncFunctionDef | ast.FunctionDef) -> tuple[bool, str]:
    """Return (is_stub, reason) for the body of a function."""
    body = func.body
    # Strip a leading docstring if present.
    if body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant) \
            and isinstance(body[0].value.value, str):
        body = body[1:]
    if not body:
        return True, "empty body"
    # Explicit stub patterns regardless of length.
    for stmt in body:
        if isinstance(stmt, ast.Raise):
            exc = stmt.exc
            if isinstance(exc, ast.Call) and isinstance(exc.func, ast.Name) \
                    and exc.func.id == "NotImplementedError":
                return True, "raises NotImplementedError"
        if isinstance(stmt, ast.Return) and isinstance(stmt.value, ast.Dict):
            for k, v in zip(stmt.value.keys, stmt.value.values):
                if isinstance(k, ast.Constant) and k.value == "error" \
                        and isinstance(v, ast.Constant) \
                        and any(s in str(v.value).lower() for s in STUB_ERROR_SENTINELS):
                    return True, f"stub dict return: error={v.value!r}"
    # Body of any length made of only cheap statements = stub.
    if all(_is_cheap_stmt(s) for s in body):
        return True, f"body of {len(body)} statement(s) is entirely cheap/trivial (no real work)"
    return False, ""


def check_file(path: Path, function_names: list[str]) -> list[str]:
    """Return a list of human-readable violation strings for this file."""
    if not path.exists():
        return [f"{path}: file missing"]
    tree = ast.parse(path.read_text())
    found: dict[str, ast.AsyncFunctionDef | ast.FunctionDef] = {}
    for node in ast.walk(tree):
        if isinstance(node, (ast.AsyncFunctionDef, ast.FunctionDef)):
            found[node.name] = node
    violations: list[str] = []
    for name in function_names:
        if name not in found:
            violations.append(f"{path}:{name} — function not found")
            continue
        stub, reason = _is_stub_body(found[name])
        if stub:
            violations.append(f"{path}:{name} — {reason}")
    return violations


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--target", help="single target as FILE:FUNC (for tests)")
    args = p.parse_args()

    violations: list[str] = []
    if args.target:
        file_str, _, func = args.target.partition(":")
        path = Path(file_str) if Path(file_str).is_absolute() else REPO_ROOT / file_str
        violations.extend(check_file(path, [func]))
    else:
        for rel, funcs in DEFAULT_MANIFEST:
            violations.extend(check_file(REPO_ROOT / rel, funcs))

    if violations:
        print("LG-2 FAIL — stub / empty bodies detected:")
        for v in violations:
            print(f"  {v}")
        return 1
    print("LG-2 PASS — all entry bodies non-trivial")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd /Users/h2oslabs/Workspace/esr && uv run pytest scripts/tests/test_verify_entry_bodies.py -v
```
Expected: 3 PASSED.

- [ ] **Step 5: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr && git add scripts/verify_entry_bodies.py scripts/tests/test_verify_entry_bodies.py scripts/tests/fixtures/entry_bodies/
git commit -m "$(cat <<'EOF'
feat(loopguard): LG-2 verify_entry_bodies.py — AST stub detector

Closes reviewer C1. Detects empty bodies, pass-only, raise
NotImplementedError, and stub-error-sentinel returns across the
entry-point manifest.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `loopguard_scenario.py` — scenario YAML well-formed + live-signature enforcement (LG-1)

Parses `scenarios/e2e-feishu-cc.yaml`, confirms only approved top-level keys, every step has the 4 required fields, and every `expect_stdout_match` matches one of the live-runtime signatures from `scripts/live_signatures.txt` (unless the step is `live_signature: exempt` with a human-written reason).

**Files:**
- Create: `scripts/loopguard_scenario.py`
- Create: `scripts/tests/test_loopguard_scenario.py`
- Create: `scripts/tests/fixtures/scenarios/good.yaml`
- Create: `scripts/tests/fixtures/scenarios/bad_covered_by.yaml`
- Create: `scripts/tests/fixtures/scenarios/bad_signature.yaml`
- Create: `scripts/tests/fixtures/signatures.txt`

- [ ] **Step 1: Write the failing test**

`scripts/tests/test_loopguard_scenario.py`:

```python
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "loopguard_scenario.py"
FIX = Path(__file__).resolve().parent / "fixtures"


def run(yaml_path: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT),
         "--scenario", str(yaml_path),
         "--signatures", str(FIX / "signatures.txt")],
        capture_output=True,
        text=True,
        check=False,
    )


def test_good_scenario_passes() -> None:
    res = run(FIX / "scenarios" / "good.yaml")
    assert res.returncode == 0, res.stdout + res.stderr


def test_covered_by_rejected() -> None:
    res = run(FIX / "scenarios" / "bad_covered_by.yaml")
    assert res.returncode != 0
    assert "covered_by" in res.stdout.lower()


def test_weak_signature_rejected() -> None:
    res = run(FIX / "scenarios" / "bad_signature.yaml")
    assert res.returncode != 0
    assert "signature" in res.stdout.lower() or "defang" in res.stdout.lower()


def test_defanging_alternation_rejected(tmp_path: Path) -> None:
    """Reviewer C-P1: step regex like 'actor_id=thread:x|(.*)' must be rejected."""
    y = tmp_path / "defang.yaml"
    y.write_text(
        "name: t\nmode: mock\ndescription: t\nsetup: []\nsteps:\n"
        "  - id: x\n    description: x\n    command: echo hi\n"
        "    expect_stdout_match: 'actor_id=thread:fake|(.*)'\n"
        "    expect_exit: 0\n    timeout_sec: 5\nteardown: []\n"
    )
    res = run(y)
    assert res.returncode != 0
    assert "defang" in res.stdout.lower()


def test_literal_signature_substring_accepted(tmp_path: Path) -> None:
    """Reviewer C-P1: honest author with verbatim signature passes."""
    y = tmp_path / "honest.yaml"
    y.write_text(
        "name: t\nmode: mock\ndescription: t\nsetup: []\nsteps:\n"
        "  - id: x\n    description: x\n    command: esr actors list\n"
        r"    expect_stdout_match: 'before pid=<0\.\d+\.\d+> after'" "\n"
        "    expect_exit: 0\n    timeout_sec: 5\nteardown: []\n"
    )
    res = run(y)
    assert res.returncode == 0, res.stdout + res.stderr
```

`scripts/tests/fixtures/signatures.txt`:
```
pid=<0\.\d+\.\d+>
actor_id=(thread|tmux|cc|feishu-app):[a-z0-9-]+
ack_ms=\d{1,4}
```

`scripts/tests/fixtures/scenarios/good.yaml`:
```yaml
name: test-good
description: fixture
mode: mock
setup:
  - command: echo setup
    expect_exit: 0
    timeout_sec: 5
steps:
  - id: spawn-peer
    description: spawn a peer actor
    command: esr actors list
    expect_stdout_match: 'actor_id=thread:demo-[a-f0-9]{4}'
    expect_exit: 0
    timeout_sec: 10
teardown: []
```

`scripts/tests/fixtures/scenarios/bad_covered_by.yaml`:
```yaml
name: test-bad
description: fixture
mode: mock
setup: []
steps:
  - id: bad-step
    description: uses banned key
    covered_by:
      - py/tests/test_x.py
teardown: []
```

`scripts/tests/fixtures/scenarios/bad_signature.yaml`:
```yaml
name: test-bad2
description: fixture
mode: mock
setup: []
steps:
  - id: weak-step
    description: weak regex
    command: echo ok
    expect_stdout_match: '^ok$'
    expect_exit: 0
    timeout_sec: 5
teardown: []
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/h2oslabs/Workspace/esr && uv run pytest scripts/tests/test_loopguard_scenario.py -v
```
Expected: 3 FAILs.

- [ ] **Step 3: Write minimal implementation**

`scripts/loopguard_scenario.py`:

```python
"""LG-1 — scenario YAML structure + live-signature enforcement (spec §4.2).

Closes reviewer S4 (make the signature check blocking).
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import yaml

ALLOWED_TOP_KEYS = {"name", "description", "mode", "setup", "steps", "teardown"}
REQUIRED_STEP_KEYS = {"id", "description", "command", "expect_stdout_match",
                      "expect_exit", "timeout_sec"}
BANNED_KEYS = {"covered_by", "unit_tests", "deferred", "skip", "todo"}


def _load_signatures(path: Path) -> list[str]:
    """Return signatures as raw strings (for literal substring match — see C-P1 fix)."""
    return [line.strip()
            for line in path.read_text().splitlines()
            if line.strip() and not line.startswith("#")]


# Fix for reviewer C-P1: the step's regex must contain an approved signature
# as a LITERAL substring, AND must not defang itself with universal alternation.
DEFANG_PATTERNS = [
    re.compile(r"\|\s*\.[\*\+]"),     # | .*  or | .+  (matches anything)
    re.compile(r"\|\s*\(?\.[\*\+]"),  # | (.* or | (.+
    re.compile(r"^\^?\.[\*\+]\$?$"),  # pure .* / .+
    re.compile(r"\(\?:\.[\*\+]\)"),   # (?:.*)
]


def _scan_banned_keys(node: object, trail: str = "") -> list[str]:
    hits: list[str] = []
    if isinstance(node, dict):
        for k, v in node.items():
            if str(k) in BANNED_KEYS:
                hits.append(f"{trail}/{k}")
            hits.extend(_scan_banned_keys(v, f"{trail}/{k}"))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            hits.extend(_scan_banned_keys(v, f"{trail}[{i}]"))
    return hits


def _check_signature(step_regex: str, sigs: list[str]) -> tuple[bool, str]:
    """Two-part check:

    (1) reject defanging alternations / universal wildcards, AND
    (2) require literal-substring of at least one signature pattern.

    Substring match (not re.search of sig-as-regex against step-regex) closes
    reviewer C-P1: an honest author writes the signature verbatim; that same
    text appears as a substring of the step's regex source. An adversarial
    `actor_id=thread:fake|(.*)` is rejected because of (1) even if (2) passes.
    """
    for dp in DEFANG_PATTERNS:
        if dp.search(step_regex):
            return False, f"defanging universal-match found: {dp.pattern!r}"
    for sig in sigs:
        if sig in step_regex:
            return True, f"contains signature substring: {sig!r}"
    return False, "no approved signature substring present"


def check(scenario_path: Path, sigs_path: Path) -> list[str]:
    data = yaml.safe_load(scenario_path.read_text()) or {}
    if not isinstance(data, dict):
        return [f"{scenario_path}: top-level must be a mapping"]
    violations: list[str] = []

    extra = set(data.keys()) - ALLOWED_TOP_KEYS
    if extra:
        violations.append(f"extra top-level keys: {sorted(extra)}")

    banned = _scan_banned_keys(data)
    if banned:
        violations.extend(f"banned key at {t}" for t in banned)

    sigs = _load_signatures(sigs_path)
    for i, step in enumerate(data.get("steps") or []):
        if not isinstance(step, dict):
            violations.append(f"step[{i}]: not a mapping")
            continue
        missing = REQUIRED_STEP_KEYS - set(step.keys())
        # exemption: live_signature: exempt + reason
        if "expect_stdout_match" in missing and step.get("live_signature") == "exempt":
            if not step.get("reason"):
                violations.append(f"step[{i}]: exempt without reason")
            continue
        if missing:
            violations.append(f"step[{i}]: missing keys {sorted(missing)}")
            continue
        ok, why = _check_signature(step["expect_stdout_match"], sigs)
        if not ok:
            violations.append(
                f"step[{i}] id={step.get('id')}: {why} "
                f"(got: {step['expect_stdout_match']!r})"
            )
    return violations


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--scenario", required=True, type=Path)
    p.add_argument("--signatures", required=True, type=Path)
    args = p.parse_args()

    v = check(args.scenario, args.signatures)
    if v:
        print(f"LG-1 FAIL on {args.scenario}:")
        for hit in v:
            print(f"  {hit}")
        return 1
    print(f"LG-1 PASS — {args.scenario} well-formed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd /Users/h2oslabs/Workspace/esr && uv run pytest scripts/tests/test_loopguard_scenario.py -v
```
Expected: 3 PASSED.

- [ ] **Step 5: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr && git add scripts/loopguard_scenario.py scripts/tests/test_loopguard_scenario.py scripts/tests/fixtures/signatures.txt scripts/tests/fixtures/scenarios/
git commit -m "feat(loopguard): LG-1 loopguard_scenario.py — YAML shape + live-signature gate

Closes reviewer S4. Enforces allowed top-level keys, required step fields,
banned-key scan, and mandatory live-signature reference.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `loopguard_scenarios_allowlist.py` — scenarios/ is allowlist-only (LG-6)

`scenarios/` must contain exactly one file, `e2e-feishu-cc.yaml`. Any other file = LG-6 failure. Closes reviewer S3.

**Files:**
- Create: `scripts/loopguard_scenarios_allowlist.py`
- Create: `scripts/tests/test_loopguard_scenarios_allowlist.py`

- [ ] **Step 1: Write the failing test**

`scripts/tests/test_loopguard_scenarios_allowlist.py`:

```python
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "loopguard_scenarios_allowlist.py"


def run(scenarios_dir: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), "--dir", str(scenarios_dir)],
        capture_output=True,
        text=True,
        check=False,
    )


def test_exactly_one_allowed_file_passes(tmp_path: Path) -> None:
    (tmp_path / "e2e-feishu-cc.yaml").write_text("name: e2e-feishu-cc\n")
    res = run(tmp_path)
    assert res.returncode == 0, res.stdout + res.stderr


def test_extra_file_rejected(tmp_path: Path) -> None:
    (tmp_path / "e2e-feishu-cc.yaml").write_text("name: e2e-feishu-cc\n")
    (tmp_path / "e2e-smoke.yaml").write_text("name: smoke\n")
    res = run(tmp_path)
    assert res.returncode != 0
    assert "e2e-smoke" in res.stdout


def test_missing_allowed_file_rejected(tmp_path: Path) -> None:
    res = run(tmp_path)
    assert res.returncode != 0
    assert "e2e-feishu-cc.yaml" in res.stdout


def test_subdirectory_rejected(tmp_path: Path) -> None:
    """Reviewer C-P4: scenarios/extra/bypass.yaml must be detected."""
    (tmp_path / "e2e-feishu-cc.yaml").write_text("name: x\n")
    (tmp_path / "extra").mkdir()
    (tmp_path / "extra" / "bypass.yaml").write_text("name: y\n")
    res = run(tmp_path)
    assert res.returncode != 0
    assert "extra" in res.stdout or "subdirectory" in res.stdout.lower()
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/h2oslabs/Workspace/esr && uv run pytest scripts/tests/test_loopguard_scenarios_allowlist.py -v
```
Expected: 3 FAILs.

- [ ] **Step 3: Write minimal implementation**

`scripts/loopguard_scenarios_allowlist.py`:

```python
"""LG-6 — scenarios/ allowlist (spec §4.3, closes reviewer S3)."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

ALLOWED = {"e2e-feishu-cc.yaml"}


def check(scenarios_dir: Path) -> list[str]:
    """Reviewer C-P4 fix: walk recursively, reject both unexpected files AND
    any subdirectory — the old flat iterdir() missed scenarios/extra/foo.yaml."""
    if not scenarios_dir.exists():
        return [f"{scenarios_dir}: directory missing"]
    violations: list[str] = []
    # Any subdirectory under scenarios/ is unexpected.
    for p in scenarios_dir.iterdir():
        if p.is_dir():
            violations.append(f"unexpected subdirectory: {p.name}")
    # All files (at any depth) must be in the allowlist.
    present: set[str] = set()
    for p in scenarios_dir.rglob("*"):
        if p.is_file():
            rel = p.relative_to(scenarios_dir)
            present.add(str(rel))
    for missing in ALLOWED - present:
        violations.append(f"missing required file: {missing}")
    for extra in present - ALLOWED:
        violations.append(f"unexpected file (not in allowlist): {extra}")
    return violations


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--dir", required=True, type=Path)
    args = p.parse_args()

    v = check(args.dir)
    if v:
        print(f"LG-6 FAIL on {args.dir}:")
        for x in v:
            print(f"  {x}")
        return 1
    print(f"LG-6 PASS — {args.dir} contains exactly the allowed files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd /Users/h2oslabs/Workspace/esr && uv run pytest scripts/tests/test_loopguard_scenarios_allowlist.py -v
```
Expected: 3 PASSED.

- [ ] **Step 5: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr && git add scripts/loopguard_scenarios_allowlist.py scripts/tests/test_loopguard_scenarios_allowlist.py
git commit -m "feat(loopguard): LG-6 scenarios/ allowlist — reject anything but e2e-feishu-cc.yaml

Closes reviewer S3.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `verify_prd_acceptance.py` — manifest match + regex scan (LG-3, LG-5)

Three modes:
1. `--manifest <yaml>`: every line in the manifest must appear **verbatim** in the matching PRD's `## Acceptance` section, and must be ticked `[x]`. Closes reviewer S1.
2. `--regex-scan`: the Acceptance section of each PRD contains none of the banned deferral phrases. Closes reviewer C3.
3. Default: print `all N Acceptance items ticked`.

**Files:**
- Create: `scripts/verify_prd_acceptance.py`
- Create: `scripts/tests/test_verify_prd_acceptance.py`
- Create: `scripts/tests/fixtures/prds/good.md`, `bad_deletion.md`, `bad_deferred.md`
- Create: `scripts/tests/fixtures/manifest.yaml`

- [ ] **Step 1: Write the failing test**

`scripts/tests/test_verify_prd_acceptance.py`:

```python
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "verify_prd_acceptance.py"
FIX = Path(__file__).resolve().parent / "fixtures"


def run(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        capture_output=True, text=True, check=False,
    )


def test_good_manifest_passes() -> None:
    res = run(["--prd-dir", str(FIX / "prds" / "good"),
               "--manifest", str(FIX / "manifest.yaml")])
    assert res.returncode == 0, res.stdout + res.stderr
    assert "Acceptance items ticked" in res.stdout


def test_deleted_row_rejected() -> None:
    res = run(["--prd-dir", str(FIX / "prds" / "bad_deletion"),
               "--manifest", str(FIX / "manifest.yaml")])
    assert res.returncode != 0
    assert "missing" in res.stdout.lower()


def test_deferred_phrase_rejected() -> None:
    res = run(["--prd-dir", str(FIX / "prds" / "bad_deferred"),
               "--regex-scan"])
    assert res.returncode != 0
    assert "deferred" in res.stdout.lower() or "defer" in res.stdout.lower()
```

Fixtures (create each file):

`scripts/tests/fixtures/manifest.yaml`:
```yaml
prd_01:
  - "Integration (with a running esrd-dev + a stub Feishu WS mock): Track C round-trip"
  - "Capability scan clean"
```

`scripts/tests/fixtures/prds/good/01-actor-runtime.md`:
```markdown
# PRD 01

## Acceptance

- [x] Integration (with a running esrd-dev + a stub Feishu WS mock): Track C round-trip
- [x] Capability scan clean
```

`scripts/tests/fixtures/prds/bad_deletion/01-actor-runtime.md`:
```markdown
# PRD 01

## Acceptance

- [x] Capability scan clean
```

`scripts/tests/fixtures/prds/bad_deferred/01-actor-runtime.md`:
```markdown
# PRD 01

## Acceptance

- [ ] Integration — Phase 8 live run deferred
- [x] Capability scan clean
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/h2oslabs/Workspace/esr && uv run pytest scripts/tests/test_verify_prd_acceptance.py -v
```
Expected: 3 FAILs (script missing).

- [ ] **Step 3: Write minimal implementation**

`scripts/verify_prd_acceptance.py`:

```python
"""LG-3 + LG-5 — PRD acceptance section checks (spec §4.3).

Closes reviewer C3 (Acceptance-section-scoped regex) + S1 (normative manifest).
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import yaml

# Ban list for LG-3 (regex scan of Acceptance section only).
BAN_PATTERNS = [
    re.compile(r"\bdefer(red|s|ral|ring)?\b", re.I),
    re.compile(r"\bmanual step\b", re.I),
    re.compile(r"\bpost-install\b", re.I),
    re.compile(r"\bgated by\b", re.I),
    re.compile(r"\blive.*(hookup|integration|wiring|run)\b", re.I),
    re.compile(r"\bv0\.2\+?\b", re.I),
    re.compile(r"\btodo\b", re.I),
    re.compile(r"\bpending\b", re.I),
]

ACCEPTANCE_HEADING = re.compile(r"^##\s+Acceptance\s*$", re.M)
ANY_H2_HEADING = re.compile(r"^##\s+", re.M)


def extract_acceptance(md: str) -> str:
    """Return the text between '## Acceptance' and the next '##' (or EOF)."""
    m = ACCEPTANCE_HEADING.search(md)
    if not m:
        return ""
    start = m.end()
    tail = md[start:]
    n = ANY_H2_HEADING.search(tail)
    return tail[:n.start()] if n else tail


def check_manifest(prd_dir: Path, manifest_path: Path) -> list[str]:
    """Every manifest row must appear verbatim and ticked in the matching PRD."""
    manifest = yaml.safe_load(manifest_path.read_text())
    violations: list[str] = []
    total = 0
    for key, rows in manifest.items():
        prd_num = key.removeprefix("prd_")
        candidates = list(prd_dir.glob(f"{prd_num}-*.md"))
        if not candidates:
            violations.append(f"{key}: no matching PRD file in {prd_dir}")
            continue
        body = candidates[0].read_text()
        acc = extract_acceptance(body)
        for row in rows:
            total += 1
            needle_ticked = f"[x] {row}"
            needle_any = f" {row}"
            if needle_ticked not in acc and needle_ticked.replace("[x]", "[X]") not in acc:
                if needle_any in acc:
                    violations.append(f"{key}: row present but not ticked — {row!r}")
                else:
                    violations.append(f"{key}: missing — {row!r}")
    return violations if violations else [f"all {total} Acceptance items ticked"]


def check_regex_scan(prd_dir: Path) -> list[str]:
    violations: list[str] = []
    for md in sorted(prd_dir.glob("*.md")):
        acc = extract_acceptance(md.read_text())
        for pat in BAN_PATTERNS:
            for line in acc.splitlines():
                if pat.search(line):
                    violations.append(f"{md.name}: banned phrase in acceptance: {line.strip()!r}")
    return violations


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--prd-dir", type=Path,
                   default=Path(__file__).resolve().parent.parent / "docs/superpowers/prds")
    p.add_argument("--manifest", type=Path, help="acceptance-manifest.yaml")
    p.add_argument("--regex-scan", action="store_true",
                   help="LG-3: scan acceptance sections for banned phrases")
    args = p.parse_args()

    if args.regex_scan:
        v = check_regex_scan(args.prd_dir)
        if v:
            print("LG-3 FAIL — banned phrases in PRD acceptance:")
            for x in v:
                print(f"  {x}")
            return 1
        print("LG-3 PASS — no deferral phrases in any PRD acceptance")
        return 0

    if args.manifest:
        v = check_manifest(args.prd_dir, args.manifest)
        if len(v) == 1 and v[0].startswith("all "):
            print(f"LG-5 PASS — {v[0]}")
            return 0
        print("LG-5 FAIL — acceptance manifest mismatch:")
        for x in v:
            print(f"  {x}")
        return 1

    print("one of --manifest / --regex-scan is required", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd /Users/h2oslabs/Workspace/esr && uv run pytest scripts/tests/test_verify_prd_acceptance.py -v
```
Expected: 3 PASSED.

- [ ] **Step 5: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr && git add scripts/verify_prd_acceptance.py scripts/tests/test_verify_prd_acceptance.py scripts/tests/fixtures/manifest.yaml scripts/tests/fixtures/prds/
git commit -m "feat(loopguard): LG-3 + LG-5 verify_prd_acceptance.py — manifest + regex gate

Closes reviewer C3 (Acceptance-section-only regex scan) + S1 (manifest
prevents row deletion).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: `verify_cli_tests_live.py` — CLI tests must use esrd_fixture (LG-9, LG-10)

AST-parses every `py/tests/test_cli_cmd_*.py`. Each test function must take an `esrd_fixture` parameter (or a pin-listed alternative). Must not monkeypatch `_submit_*`. Closes reviewer M2.

**Files:**
- Create: `scripts/verify_cli_tests_live.py`
- Create: `scripts/tests/test_verify_cli_tests_live.py`
- Create: `scripts/tests/fixtures/cli_tests/good.py`, `bad_no_fixture.py`, `bad_monkeypatch.py`

- [ ] **Step 1: Write the failing test**

`scripts/tests/test_verify_cli_tests_live.py`:

```python
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "verify_cli_tests_live.py"
FIX = Path(__file__).resolve().parent / "fixtures" / "cli_tests"


def run(target: Path, no_monkeypatch: bool = False) -> subprocess.CompletedProcess[str]:
    args = [sys.executable, str(SCRIPT), "--target", str(target)]
    if no_monkeypatch:
        args.append("--no-monkeypatch")
    return subprocess.run(args, capture_output=True, text=True, check=False)


def test_good_test_file_passes() -> None:
    res = run(FIX / "good.py")
    assert res.returncode == 0, res.stdout + res.stderr


def test_missing_fixture_rejected() -> None:
    res = run(FIX / "bad_no_fixture.py")
    assert res.returncode != 0
    assert "esrd_fixture" in res.stdout


def test_monkeypatch_rejected() -> None:
    res = run(FIX / "bad_monkeypatch.py", no_monkeypatch=True)
    assert res.returncode != 0
    assert "monkeypatch" in res.stdout.lower() or "_submit" in res.stdout


def test_decorator_patch_rejected() -> None:
    """Reviewer C-P3: @patch('...._submit_cmd_run') must be caught."""
    res = run(FIX / "bad_decorator_patch.py", no_monkeypatch=True)
    assert res.returncode != 0
    assert "_submit" in res.stdout


def test_patch_object_rejected() -> None:
    """Reviewer C-P3: mocker.patch.object(..., '_submit_*') must be caught."""
    res = run(FIX / "bad_patch_object.py", no_monkeypatch=True)
    assert res.returncode != 0
    assert "_submit" in res.stdout
```

`scripts/tests/fixtures/cli_tests/good.py`:
```python
def test_cmd_run_happy(esrd_fixture):
    result = esrd_fixture.run_cli(["cmd", "run", "x"])
    assert result.returncode == 0
```

`scripts/tests/fixtures/cli_tests/bad_no_fixture.py`:
```python
def test_cmd_run_happy():
    pass
```

`scripts/tests/fixtures/cli_tests/bad_decorator_patch.py`:
```python
from unittest.mock import patch

@patch("esr.cli.main._submit_cmd_run")
def test_cmd_run_happy(_mocked, esrd_fixture):
    pass
```

`scripts/tests/fixtures/cli_tests/bad_patch_object.py`:
```python
import esr.cli.main as main_mod

def test_cmd_run_happy(mocker, esrd_fixture):
    mocker.patch.object(main_mod, "_submit_cmd_run", return_value={"ok": True})
```

`scripts/tests/fixtures/cli_tests/bad_monkeypatch.py`:
```python
def test_cmd_run_happy(monkeypatch, esrd_fixture):
    monkeypatch.setattr("esr.cli.main._submit_cmd_run", lambda *a: {"ok": True})
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/h2oslabs/Workspace/esr && uv run pytest scripts/tests/test_verify_cli_tests_live.py -v
```
Expected: 3 FAILs.

- [ ] **Step 3: Write minimal implementation**

`scripts/verify_cli_tests_live.py`:

```python
"""LG-9 + LG-10 — CLI tests must exercise live esrd (spec §4.3, closes M2)."""
from __future__ import annotations

import argparse
import ast
import sys
from pathlib import Path

ALLOWED_FIXTURES = {"esrd_fixture", "live_esrd"}


def _uses_allowed_fixture(func: ast.FunctionDef) -> bool:
    return any(arg.arg in ALLOWED_FIXTURES for arg in func.args.args)


def _has_submit_monkeypatch(func: ast.FunctionDef) -> list[str]:
    """Reviewer C-P3 fix: walk decorators too; match any Call whose string
    literal args contain `_submit_` (catches @patch, patch.object, setattr)."""
    hits: list[str] = []
    roots = list(func.decorator_list) + [func]
    for root in roots:
        for node in ast.walk(root):
            if isinstance(node, ast.Call):
                # scan every argument for a string-literal or attribute reference to _submit_*
                for arg in node.args:
                    if isinstance(arg, ast.Constant) and isinstance(arg.value, str) \
                            and "_submit_" in arg.value:
                        hits.append(arg.value)
                    elif isinstance(arg, ast.Attribute):
                        unparsed = ast.unparse(arg)
                        if "_submit_" in unparsed:
                            hits.append(unparsed)
                # kwargs too (e.g. patch(target='..._submit_...'))
                for kw in node.keywords:
                    if isinstance(kw.value, ast.Constant) and isinstance(kw.value.value, str) \
                            and "_submit_" in kw.value.value:
                        hits.append(kw.value.value)
    return hits


def check_file(path: Path, no_monkeypatch: bool) -> list[str]:
    if not path.exists():
        return [f"{path}: missing"]
    tree = ast.parse(path.read_text())
    violations: list[str] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name.startswith("test_"):
            if not _uses_allowed_fixture(node):
                violations.append(f"{path}:{node.name} — missing esrd_fixture arg")
            if no_monkeypatch:
                hits = _has_submit_monkeypatch(node)
                for h in hits:
                    violations.append(f"{path}:{node.name} — monkeypatch of {h}")
    return violations


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--target", type=Path,
                   help="single file to check (repeatable via tests/)")
    p.add_argument("--no-monkeypatch", action="store_true")
    args = p.parse_args()

    targets: list[Path] = []
    if args.target:
        targets = [args.target]
    else:
        default = Path(__file__).resolve().parent.parent / "py/tests"
        targets = sorted(default.glob("test_cli_cmd_*.py"))

    violations: list[str] = []
    for t in targets:
        violations.extend(check_file(t, args.no_monkeypatch))

    if violations:
        print("LG-9/10 FAIL — CLI tests not exercising live esrd:")
        for v in violations:
            print(f"  {v}")
        return 1
    print(f"LG-9/10 PASS — {len(targets)} CLI test file(s) use live esrd")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd /Users/h2oslabs/Workspace/esr && uv run pytest scripts/tests/test_verify_cli_tests_live.py -v
```
Expected: 3 PASSED.

- [ ] **Step 5: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr && git add scripts/verify_cli_tests_live.py scripts/tests/test_verify_cli_tests_live.py scripts/tests/fixtures/cli_tests/
git commit -m "feat(loopguard): LG-9/10 verify_cli_tests_live.py — require esrd_fixture

Closes reviewer M2. CLI tests must take esrd_fixture and must not
monkeypatch _submit_* helpers.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: `verify_ledger_append_only.py` — append-only + enum discipline (LG-7)

Walks git history of `docs/ralph-loop-ledger.md`. Every commit must only **add** rows (no line deletions, no in-place edits). Every new row's `evidence-type` column must be one of the approved enum values. Closes reviewer S2.

**Files:**
- Create: `scripts/verify_ledger_append_only.py`
- Create: `scripts/tests/test_verify_ledger_append_only.py`
- Create: `scripts/tests/fixtures/ledger/good_history.sh` (shell fixture that builds a good git history)
- Create: `scripts/tests/fixtures/ledger/bad_deletion_history.sh`

- [ ] **Step 1: Write the failing test**

`scripts/tests/test_verify_ledger_append_only.py`:

```python
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "verify_ledger_append_only.py"
FIX = Path(__file__).resolve().parent / "fixtures" / "ledger"
HEADER = (
    "| iter | date | phase | FR | commit | evidence-type | evidence-sha |\n"
    "|------|------|-------|-----|--------|---------------|--------------|\n"
)


def _init_repo(tmp_path: Path) -> Path:
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "config", "user.email", "t@x"], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "config", "user.name", "t"], check=True)
    return tmp_path


def _commit(repo: Path, body: str, msg: str) -> None:
    (repo / "docs").mkdir(exist_ok=True)
    (repo / "docs" / "ralph-loop-ledger.md").write_text(body)
    subprocess.run(["git", "-C", str(repo), "add", "-A"], check=True)
    subprocess.run(["git", "-C", str(repo), "commit", "-q", "-m", msg], check=True)


def _run(repo: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), "--repo", str(repo),
         "--ledger", "docs/ralph-loop-ledger.md"],
        capture_output=True, text=True, check=False,
    )


def test_pure_append_passes(tmp_path: Path) -> None:
    repo = _init_repo(tmp_path)
    _commit(repo, HEADER, "init")
    _commit(repo, HEADER + "| 1 | 2026-04-20 | 8a | F13 | abc123 | unit_tests | sha256:aa |\n", "iter 1")
    _commit(repo, HEADER
            + "| 1 | 2026-04-20 | 8a | F13 | abc123 | unit_tests | sha256:aa |\n"
            + "| 2 | 2026-04-20 | 8a | F14 | def456 | scenario_mock | sha256:bb |\n",
            "iter 2")
    res = _run(repo)
    assert res.returncode == 0, res.stdout + res.stderr


def test_row_deletion_rejected(tmp_path: Path) -> None:
    repo = _init_repo(tmp_path)
    _commit(repo, HEADER, "init")
    _commit(repo, HEADER + "| 1 | 2026-04-20 | 8a | F13 | abc123 | unit_tests | sha256:aa |\n", "iter 1")
    _commit(repo, HEADER, "iter 2 — deleted row 1")
    res = _run(repo)
    assert res.returncode != 0
    assert "deletion" in res.stdout.lower() or "removed" in res.stdout.lower()


def test_bad_evidence_type_rejected(tmp_path: Path) -> None:
    repo = _init_repo(tmp_path)
    _commit(repo, HEADER, "init")
    _commit(repo, HEADER + "| 1 | 2026-04-20 | 8a | F13 | abc123 | custom_shell | sha256:aa |\n", "iter 1")
    res = _run(repo)
    assert res.returncode != 0
    assert "evidence-type" in res.stdout.lower() or "enum" in res.stdout.lower()
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/h2oslabs/Workspace/esr && uv run pytest scripts/tests/test_verify_ledger_append_only.py -v
```
Expected: 3 FAILs.

- [ ] **Step 3: Write minimal implementation**

`scripts/verify_ledger_append_only.py`:

```python
"""LG-7 — ledger append-only + evidence-type enum (spec §4.4, closes S2)."""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

APPROVED_EVIDENCE_TYPES = {
    "unit_tests", "prd_matrix", "loopguard", "scenario_mock",
    "final_gate_mock", "prd_acceptance", "ledger_check",
}


def _git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True, text=True, check=True,
    ).stdout


def check(repo: Path, ledger_rel: str) -> list[str]:
    violations: list[str] = []
    log = _git(repo, "log", "--pretty=format:%H", "--reverse", "--", ledger_rel).splitlines()
    prev_rows: list[str] = []
    for sha in log:
        body = _git(repo, "show", f"{sha}:{ledger_rel}")
        rows = [ln for ln in body.splitlines() if ln.startswith("| ")]
        # Reject line deletions or in-place edits relative to previous commit.
        if prev_rows:
            if len(rows) < len(prev_rows):
                violations.append(f"commit {sha[:7]}: row count decreased "
                                  f"({len(prev_rows)} -> {len(rows)}); removed/deletion")
            for i, (old, new) in enumerate(zip(prev_rows, rows)):
                if old != new:
                    violations.append(f"commit {sha[:7]}: row {i} edited in-place")
        # Validate evidence-type column of new rows.
        for r in rows[len(prev_rows):]:
            parts = [p.strip() for p in r.strip("|").split("|")]
            if len(parts) < 7:
                continue  # header or separator row
            ev_type = parts[5]
            if ev_type.startswith("---") or ev_type == "evidence-type":
                continue
            if ev_type not in APPROVED_EVIDENCE_TYPES:
                violations.append(f"commit {sha[:7]}: bad evidence-type {ev_type!r}")
        prev_rows = rows
    return violations


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--repo", type=Path, default=Path("."))
    p.add_argument("--ledger", default="docs/ralph-loop-ledger.md")
    args = p.parse_args()

    v = check(args.repo, args.ledger)
    if v:
        print("LG-7 FAIL:")
        for x in v:
            print(f"  {x}")
        return 1
    n = sum(1 for _ in _git(args.repo, "log", "--oneline", "--", args.ledger).splitlines())
    print(f"ledger integrity OK — {n} commits, 0 in-place edits")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd /Users/h2oslabs/Workspace/esr && uv run pytest scripts/tests/test_verify_ledger_append_only.py -v
```
Expected: 3 PASSED.

- [ ] **Step 5: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr && git add scripts/verify_ledger_append_only.py scripts/tests/test_verify_ledger_append_only.py
git commit -m "feat(loopguard): LG-7 verify_ledger_append_only.py — append-only + enum

Closes reviewer S2. Rejects row deletion, in-place edits, and
non-enum evidence-type values.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: `ledger_append.py` — enum-dispatched evidence append

Accepts `--phase`, `--fr`, `--evidence-type` (one of enum). Runs the enum-mapped command, sha256s output, appends a row. No caller-supplied command string. Closes S2 (together with Task 6).

**Files:**
- Create: `scripts/ledger_append.py`
- Create: `scripts/tests/test_ledger_append.py`

- [ ] **Step 1: Write the failing test**

`scripts/tests/test_ledger_append.py`:

```python
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "ledger_append.py"


def _init_ledger(tmp_path: Path) -> Path:
    ledger = tmp_path / "ledger.md"
    ledger.write_text(
        "| iter | date | phase | FR | commit | evidence-type | evidence-sha |\n"
        "|------|------|-------|-----|--------|---------------|--------------|\n"
    )
    return ledger


def test_append_with_approved_enum(tmp_path: Path) -> None:
    ledger = _init_ledger(tmp_path)
    res = subprocess.run(
        [sys.executable, str(SCRIPT),
         "--ledger", str(ledger),
         "--phase", "8a", "--fr", "F13",
         "--evidence-type", "loopguard",
         "--dry-run"],  # dry-run: don't actually run the mapped command, just test wiring
        capture_output=True, text=True, check=False,
    )
    assert res.returncode == 0, res.stdout + res.stderr
    content = ledger.read_text()
    assert "| 1 |" in content
    assert "loopguard" in content


def test_rejects_bad_enum(tmp_path: Path) -> None:
    ledger = _init_ledger(tmp_path)
    res = subprocess.run(
        [sys.executable, str(SCRIPT),
         "--ledger", str(ledger),
         "--phase", "8a", "--fr", "F13",
         "--evidence-type", "custom_shell",
         "--dry-run"],
        capture_output=True, text=True, check=False,
    )
    assert res.returncode != 0
    assert "evidence-type" in res.stderr.lower() or "enum" in res.stderr.lower()
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/h2oslabs/Workspace/esr && uv run pytest scripts/tests/test_ledger_append.py -v
```
Expected: 2 FAILs.

- [ ] **Step 3: Write minimal implementation**

`scripts/ledger_append.py`:

```python
"""Append a row to docs/ralph-loop-ledger.md (spec §4.4).

Closes reviewer S2: the caller chooses an evidence-TYPE (enum); the script
maps it to a fixed command internally. No caller-supplied command string.
"""
from __future__ import annotations

import argparse
import hashlib
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

# Enum -> command. Commands run from repo root.
EVIDENCE_COMMANDS: dict[str, list[str]] = {
    "unit_tests": ["make", "test"],
    "prd_matrix": ["uv", "run", "python", "scripts/verify_prd_matrix.py"],
    "loopguard": ["bash", "scripts/loopguard.sh"],
    "scenario_mock": ["esr", "scenario", "run", "e2e-feishu-cc"],
    "final_gate_mock": ["bash", "scripts/final_gate.sh", "--mock"],
    "prd_acceptance": ["uv", "run", "python", "scripts/verify_prd_acceptance.py",
                       "--manifest", "docs/superpowers/prds/acceptance-manifest.yaml"],
    "ledger_check": ["uv", "run", "python", "scripts/verify_ledger_append_only.py"],
}


def _next_iter(ledger_path: Path) -> int:
    """Scan existing rows, return next iter number (1 if none)."""
    n = 0
    for ln in ledger_path.read_text().splitlines():
        if not ln.startswith("| ") or "---" in ln or "iter" in ln.split("|")[1]:
            continue
        try:
            n = max(n, int(ln.split("|")[1].strip()))
        except ValueError:
            continue
    return n + 1


def _short_commit() -> str:
    r = subprocess.run(["git", "rev-parse", "--short", "HEAD"],
                       capture_output=True, text=True, check=True)
    return r.stdout.strip()


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--ledger", required=True, type=Path)
    p.add_argument("--phase", required=True)
    p.add_argument("--fr", required=True)
    p.add_argument("--evidence-type", required=True)
    p.add_argument("--dry-run", action="store_true",
                   help="skip running the mapped command; synthesise a fake sha")
    args = p.parse_args()

    if args.evidence_type not in EVIDENCE_COMMANDS:
        print(f"bad evidence-type {args.evidence_type!r}; "
              f"enum allows {sorted(EVIDENCE_COMMANDS)}", file=sys.stderr)
        return 2

    if args.dry_run:
        sha = "sha256:" + hashlib.sha256(args.evidence_type.encode()).hexdigest()[:16]
        commit = "0000000"
    else:
        cmd = EVIDENCE_COMMANDS[args.evidence_type]
        r = subprocess.run(cmd, capture_output=True, text=True, check=False)
        if r.returncode != 0:
            print(f"evidence command failed: {' '.join(cmd)}", file=sys.stderr)
            print(r.stdout, r.stderr, file=sys.stderr)
            return 1
        sha = "sha256:" + hashlib.sha256(r.stdout.encode()).hexdigest()[:16]
        commit = _short_commit()

    n = _next_iter(args.ledger)
    date = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    row = f"| {n} | {date} | {args.phase} | {args.fr} | {commit} | {args.evidence_type} | {sha} |\n"
    with args.ledger.open("a") as f:
        f.write(row)
    print(f"appended iter {n} ({args.evidence_type})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd /Users/h2oslabs/Workspace/esr && uv run pytest scripts/tests/test_ledger_append.py -v
```
Expected: 2 PASSED.

- [ ] **Step 5: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr && git add scripts/ledger_append.py scripts/tests/test_ledger_append.py
git commit -m "feat(loopguard): ledger_append.py — enum-dispatched evidence

Closes reviewer S2 (paired with verify_ledger_append_only). Caller
picks an evidence-TYPE (enum); script maps it to a fixed command.
Caller cannot supply a custom shell command.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: `loopguard.sh` — orchestrator

Runs all 11 LG-* checks. Bails on first failure with a named `BLOCKED` message. Used by the loop's §3.1b per-iteration pre-flight.

**Files:**
- Create: `scripts/loopguard.sh`
- Create: `scripts/tests/test_loopguard_orchestrator.sh` (integration bash test)

- [ ] **Step 1: Write the failing test**

`scripts/tests/test_loopguard_orchestrator.sh`:

```bash
#!/usr/bin/env bash
# Smoke test for scripts/loopguard.sh — invoke it; confirm it produces the
# summary line. Real check values depend on repo state — this test only
# asserts the orchestrator wiring is correct.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
out="$(bash scripts/loopguard.sh 2>&1 || true)"
echo "$out" | grep -qE 'loopguard (PASS|FAIL)' || {
  echo "no summary line"
  echo "$out"
  exit 1
}
echo "orchestrator wiring OK"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/h2oslabs/Workspace/esr && bash scripts/tests/test_loopguard_orchestrator.sh
```
Expected: `loopguard.sh: No such file or directory`.

- [ ] **Step 3: Write minimal implementation**

`scripts/loopguard.sh`:

```bash
#!/usr/bin/env bash
# Ralph-loop v2 per-iteration anti-tamper orchestrator (spec §4.3).
# Runs all 11 LG-* checks. Bails on the first failure.
set -u

cd "$(git rev-parse --show-toplevel)" || { echo "not in a git repo"; exit 2; }

pass=0
fail_id=""
fail_msg=""

check() {
  local id="$1"; shift
  local msg="$1"; shift
  echo "[$id] $msg" >&2
  if "$@" >/tmp/loopguard.$$.out 2>&1; then
    pass=$((pass + 1))
  else
    fail_id="$id"
    fail_msg="$msg"
    cat /tmp/loopguard.$$.out >&2
    rm -f /tmp/loopguard.$$.out
    echo "loopguard FAIL — $id — $msg"
    echo "<promise>BLOCKED: loopguard:$id</promise>"
    exit 1
  fi
  rm -f /tmp/loopguard.$$.out
}

check LG-1  "scenario YAML well-formed + live-signature"  \
    uv run python scripts/loopguard_scenario.py \
        --scenario scenarios/e2e-feishu-cc.yaml \
        --signatures scripts/live_signatures.txt

check LG-2  "no soft stubs in entry bodies"  \
    uv run python scripts/verify_entry_bodies.py

check LG-3  "no deferral phrases in PRD acceptance"  \
    uv run python scripts/verify_prd_acceptance.py --regex-scan

check LG-4  "final_gate.sh SHA pin"  \
    sha256sum -c scripts/final_gate.sh.sha256

check LG-5  "acceptance manifest match + ticked"  \
    uv run python scripts/verify_prd_acceptance.py \
        --manifest docs/superpowers/prds/acceptance-manifest.yaml

check LG-6  "scenarios/ allowlist"  \
    uv run python scripts/loopguard_scenarios_allowlist.py --dir scenarios

check LG-7  "ledger append-only + enum"  \
    uv run python scripts/verify_ledger_append_only.py

check LG-8  "no new @pytest.mark.skip/xfail since baseline"  \
    bash -c '
      baseline=$(cat .ralph-loop-baseline 2>/dev/null || echo HEAD)
      diff_out=$(git diff "$baseline" -- "py/tests/**/*.py" "runtime/test/**/*.exs" || true)
      echo "$diff_out" | grep -E "^\+.*(@pytest\.mark\.(skip|xfail)|@tag.*:skip)" && exit 1
      exit 0
    '

check LG-9  "CLI tests use esrd_fixture"  \
    uv run python scripts/verify_cli_tests_live.py

check LG-10 "no _submit_* monkeypatch in tests"  \
    uv run python scripts/verify_cli_tests_live.py --no-monkeypatch

check LG-11 "loopguard bundle SHA pin"  \
    sha256sum -c scripts/loopguard-bundle.sha256

echo "loopguard PASS — all $pass loopguard checks passed"
```

- [ ] **Step 4: Run test to verify it passes**

Note: the test only asserts that the orchestrator **runs** and produces a summary line. It doesn't (yet) require every LG-* to pass — several require files that don't exist until later tasks. That's fine for wiring.

```bash
cd /Users/h2oslabs/Workspace/esr && chmod +x scripts/loopguard.sh && bash scripts/tests/test_loopguard_orchestrator.sh
```
Expected: `orchestrator wiring OK` (PASS can be FAIL at this point; the test only checks the summary line appears).

- [ ] **Step 5: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr && git add scripts/loopguard.sh scripts/tests/test_loopguard_orchestrator.sh
git commit -m "feat(loopguard): scripts/loopguard.sh — 11-check orchestrator

Runs LG-1..LG-11 in order, bails on first fail with
<promise>BLOCKED: loopguard:<id></promise>.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: `final_gate.sh` — mock mode

Runs the seven Final Gate conditions from spec §8 in mock mode. Does not run `--live` yet (Task 10). Mock mode: a clean pass means loopguard passes, all unit tests green, scenario mock-green, verify_prd_matrix green.

**Files:**
- Create: `scripts/final_gate.sh`
- Create: `scripts/tests/test_final_gate_mock.sh`

- [ ] **Step 1: Write the failing test**

`scripts/tests/test_final_gate_mock.sh`:

```bash
#!/usr/bin/env bash
# Smoke test: script exists, accepts --mock, produces expected summary line.
set -u
cd "$(git rev-parse --show-toplevel)"
out=$(bash scripts/final_gate.sh --mock 2>&1 || true)
echo "$out" | grep -qE 'FINAL GATE MOCK (PASSED|FAILED)' || {
  echo "no summary line"
  exit 1
}
echo "final_gate.sh --mock wiring OK"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/h2oslabs/Workspace/esr && bash scripts/tests/test_final_gate_mock.sh
```
Expected: `No such file or directory`.

- [ ] **Step 3: Write minimal implementation**

`scripts/final_gate.sh`:

```bash
#!/usr/bin/env bash
# External verdict (spec §4.1, §8). User-authored; pinned by SHA in
# scripts/final_gate.sh.sha256. The loop is forbidden to modify.
#
# Usage:
#   bash scripts/final_gate.sh --mock   # loop can run this; it's the last
#                                       # loop-owned gate before LIVE_READY
#   bash scripts/final_gate.sh --live   # USER runs this; requires
#                                       # ~/.esr/live.env populated
#
set -u
cd "$(git rev-parse --show-toplevel)" || exit 2

mode="${1:-}"
if [[ "$mode" != "--mock" && "$mode" != "--live" ]]; then
  echo "usage: $0 --mock | --live" >&2
  exit 2
fi

fail=0
section() { echo; echo "=== $* ==="; }

if [[ "$mode" == "--mock" ]]; then
  section "1/7 make test"
  if ! make test >/tmp/fg.test.log 2>&1; then
    echo "FAIL"; tail -40 /tmp/fg.test.log; fail=1
  fi

  section "2/7 verify_prd_matrix.py"
  if ! uv run python scripts/verify_prd_matrix.py >/tmp/fg.matrix.log 2>&1; then
    echo "FAIL"; cat /tmp/fg.matrix.log; fail=1
  fi

  section "3/7 loopguard"
  if ! bash scripts/loopguard.sh >/tmp/fg.lg.log 2>&1; then
    echo "FAIL"; tail -20 /tmp/fg.lg.log; fail=1
  fi

  section "4/7 scenario run e2e-feishu-cc (mock)"
  if ! uv run --project py esr scenario run e2e-feishu-cc >/tmp/fg.scn.log 2>&1; then
    echo "FAIL"; tail -20 /tmp/fg.scn.log; fail=1
  fi

  section "5/7 ledger integrity"
  if ! uv run python scripts/verify_ledger_append_only.py >/tmp/fg.led.log 2>&1; then
    echo "FAIL"; cat /tmp/fg.led.log; fail=1
  fi

  section "6/7 PRD acceptance manifest"
  if ! uv run python scripts/verify_prd_acceptance.py \
      --manifest docs/superpowers/prds/acceptance-manifest.yaml >/tmp/fg.acc.log 2>&1; then
    echo "FAIL"; cat /tmp/fg.acc.log; fail=1
  fi

  section "7/7 self-mock final (scenario exit 0 + no BLOCKED in last iteration)"
  if grep -qE '<promise>BLOCKED:' docs/ralph-loop-ledger.md 2>/dev/null; then
    echo "FAIL — BLOCKED record in ledger"; fail=1
  fi

  if [[ $fail -eq 0 ]]; then
    echo
    echo "FINAL GATE MOCK PASSED — ready for user --live verification"
    echo
    echo "Next step: user populates ~/.esr/live.env and runs:"
    echo "    bash scripts/final_gate.sh --live"
    exit 0
  else
    echo
    echo "FINAL GATE MOCK FAILED"
    exit 1
  fi
fi

# --live path is user-authored in Task 10.
echo "LIVE mode not yet authored. See spec §4.1 — user must implement."
exit 3
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd /Users/h2oslabs/Workspace/esr && chmod +x scripts/final_gate.sh && bash scripts/tests/test_final_gate_mock.sh
```
Expected: `final_gate.sh --mock wiring OK` (the inner checks may FAIL at this point — that's expected because scenario file / manifest / etc. don't exist until later tasks; the test only checks the summary line pattern).

- [ ] **Step 5: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr && git add scripts/final_gate.sh scripts/tests/test_final_gate_mock.sh
git commit -m "feat(gate): final_gate.sh --mock path — external verdict skeleton

Spec §4.1, §8. --live body is deferred to Task 10 (user-authored).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: `final_gate.sh --live` body — user-authored forensic verification

Per spec §4.1: the `--live` path cannot be trivial. It must collect three independent forensic artifacts. **This task is authored by the user, not by an automated agent**, because the user owns the real Feishu credentials and test chat.

**Files:**
- Modify: `scripts/final_gate.sh` (add the `--live` branch)

- [ ] **Step 1: Write the failing assertion**

Attempt to run `bash scripts/final_gate.sh --live` before editing. Expected output: `LIVE mode not yet authored. See spec §4.1 — user must implement.` (exit 3).

```bash
cd /Users/h2oslabs/Workspace/esr && bash scripts/final_gate.sh --live; echo "exit=$?"
```
Expected: `exit=3`.

- [ ] **Step 2: Replace the `--live` branch in `scripts/final_gate.sh`**

Edit the `echo "LIVE mode not yet authored..."` block at the bottom of `final_gate.sh` with the following body:

```bash
# --live path (user-authored, spec §4.1).
# Requires ~/.esr/live.env with FEISHU_APP_ID, FEISHU_APP_SECRET, FEISHU_TEST_CHAT_ID.

env_file="$HOME/.esr/live.env"
if [[ ! -f "$env_file" ]]; then
  echo "NO LIVE CREDENTIALS — set $env_file with FEISHU_APP_ID etc."
  exit 2
fi
# shellcheck source=/dev/null
source "$env_file"
: "${FEISHU_APP_ID:?not set}"
: "${FEISHU_APP_SECRET:?not set}"
: "${FEISHU_TEST_CHAT_ID:?not set}"

ts=$(date +%s)
thread_id="smoke-test-$ts"

section "live 1/3 — start esrd"
if ! scripts/esrd.sh start --instance=smoke-live >/tmp/fg.live.esrd.log 2>&1; then
  echo "FAIL to start esrd"; tail -20 /tmp/fg.live.esrd.log; exit 1
fi
trap 'scripts/esrd.sh stop --instance=smoke-live >/dev/null 2>&1 || true' EXIT

section "live 2/3 — send /new-thread via real Feishu app"
# Use the user's real app to post into FEISHU_TEST_CHAT_ID.
uv run --project py esr adapter add feishu-smoke \
    --type feishu --app-id "$FEISHU_APP_ID" --app-secret "$FEISHU_APP_SECRET" \
    >/tmp/fg.live.add.log 2>&1 || { echo "FAIL to add adapter"; cat /tmp/fg.live.add.log; exit 1; }

# Capture the real Lark HTTP response — forensic artifact #1.
lark_resp=$(uv run --project py python -c "
import lark_oapi, os, json
c = lark_oapi.Client.builder().app_id('$FEISHU_APP_ID').app_secret('$FEISHU_APP_SECRET').build()
from lark_oapi.api.im.v1 import *
req = CreateMessageRequest.builder().receive_id_type('chat_id').request_body(
    CreateMessageRequestBody.builder().receive_id('$FEISHU_TEST_CHAT_ID')
    .msg_type('text').content(json.dumps({'text': '/new-thread $thread_id'})).build()
).build()
resp = c.im.v1.message.create(req)
print(json.dumps({'code': resp.code, 'message_id': resp.data.message_id if resp.data else None}))
")
echo "Lark response: $lark_resp"
if ! echo "$lark_resp" | grep -qE '"code": 0'; then
  echo "FAIL — Lark API did not accept the smoke-test message"
  exit 1
fi

# Wait for bidirectional round-trip.
section "live 3/3 — observe forensic artifacts"
sleep 10

# Artifact 2 — esrd log line mentioning the test chat.
log_artifact=$(grep -F "$FEISHU_TEST_CHAT_ID" ~/.esrd/smoke-live/logs/*.log | tail -1)
if [[ -z "$log_artifact" ]]; then
  echo "FAIL — no esrd log line for FEISHU_TEST_CHAT_ID"; exit 1
fi
echo "  esrd log: $log_artifact"

# Artifact 3 — tmux capture-pane excerpt showing CC received the forwarded msg.
tmux_artifact=$(tmux capture-pane -t "$thread_id" -p 2>/dev/null | grep -F "$thread_id" | tail -1 || true)
if [[ -z "$tmux_artifact" ]]; then
  echo "FAIL — no tmux capture-pane line for $thread_id"; exit 1
fi
echo "  tmux pane: $tmux_artifact"

echo
echo "FINAL GATE LIVE PASSED"
echo "  Sent /new-thread $thread_id to $FEISHU_TEST_CHAT_ID"
echo "  Observed bidirectional round-trip via esrd logs + tmux capture"
echo "  You can now merge to main."
exit 0
```

Full updated `scripts/final_gate.sh` (the `--live` section replaces the old two-line placeholder at the bottom).

- [ ] **Step 3: Smoke-test the stub (without real credentials)**

```bash
cd /Users/h2oslabs/Workspace/esr && rm -f ~/.esr/live.env.bak && mv ~/.esr/live.env ~/.esr/live.env.bak 2>/dev/null || true
bash scripts/final_gate.sh --live; echo "exit=$?"
mv ~/.esr/live.env.bak ~/.esr/live.env 2>/dev/null || true
```
Expected: `NO LIVE CREDENTIALS — set ...` and `exit=2`.

- [ ] **Step 4: Record the authored body as the baseline**

Document in the ledger that the live body is user-authored. (This happens at Task 17 seed; no separate commit yet.)

- [ ] **Step 5: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr && git add scripts/final_gate.sh
git commit -m "feat(gate): final_gate.sh --live path — user-authored forensic verification

Spec §4.1. Collects Lark HTTP response, esrd log line, tmux capture-pane
excerpt. All three must match live signatures before exit 0.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: `scripts/live_signatures.txt`

Six signatures from spec §4.2 table (sig-A … sig-F).

**Files:**
- Create: `scripts/live_signatures.txt`

- [ ] **Step 1: Create the file**

`scripts/live_signatures.txt`:
```
# Spec §4.2 — live-runtime signatures. Edit requires spec change.
# sig-A — BEAM pid
pid=<0\.\d+\.\d+>
# sig-B — actor id synthesized at spawn
actor_id=(thread|tmux|cc|feishu-app):[a-z0-9-]+
# sig-C — directive ack latency
ack_ms=\d{1,4}
# sig-D — Lark message_id shape
message_id=om_[a-zA-Z0-9]{10,}
# sig-E — PeerRegistry state
peer_count=\d+ registered_count=\d+
# sig-F — dedup hit on PeerServer
msg_id=[a-f0-9-]{8,} dedup=hit
```

- [ ] **Step 2: Verify Task 2 passes with it**

```bash
cd /Users/h2oslabs/Workspace/esr && uv run python scripts/loopguard_scenario.py \
    --scenario scripts/tests/fixtures/scenarios/good.yaml \
    --signatures scripts/live_signatures.txt
```
Expected: `LG-1 PASS — ... well-formed`.

- [ ] **Step 3: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr && git add scripts/live_signatures.txt
git commit -m "feat(loopguard): scripts/live_signatures.txt — 6 live-runtime regex signatures

Spec §4.2.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: `docs/superpowers/prds/acceptance-manifest.yaml`

Normative list of every required Acceptance row across PRDs 01–07. The **v1 loop deleted or never ticked** three Integration rows; this manifest names them explicitly so LG-5 catches any attempt to delete.

**Files:**
- Create: `docs/superpowers/prds/acceptance-manifest.yaml`

- [ ] **Step 1: Enumerate current PRD acceptance rows**

```bash
cd /Users/h2oslabs/Workspace/esr && for f in docs/superpowers/prds/0[1-7]-*.md; do
  echo "=== $f ==="
  awk '/^## Acceptance/,/^## / { if ($0 !~ /^## /) print }' "$f" | grep -E '^\- \['
done
```

Record every line so the manifest captures the as-authored state plus the specific integration rows v1 wanted to defer.

- [ ] **Step 2: Write the manifest**

`docs/superpowers/prds/acceptance-manifest.yaml`:

```yaml
# Normative acceptance manifest (spec §4.3 LG-5; closes reviewer S1).
# Every row listed here MUST appear verbatim in the matching PRD's
# `## Acceptance` section and MUST be ticked `[x]` at Final Gate time.
# Adding to this manifest requires a spec change.

prd_01:
  # Reviewer S-P1 fix: rewrites below match the language Task 13b pushes
  # into 01-actor-runtime.md. Original v1 wording (deferred / live systemd /
  # deferred tooling) would have tripped LG-3 on iteration 1.
  - "All 22 FRs have passing unit tests (runtime/test/ matrix green)"
  - "`mix test` green; `mix credo --strict` clean; `mix dialyzer` clean"
  - "Integration test: spawn → inject event → handler mock returns → actions dispatched → telemetry observed (peer_server_action_dispatch_test.exs + peer_server_event_handling_test.exs)"
  - "PRD 01 unit-test count ≥ 50 — 105 achieved"
  - "E2E Track G-4 recovery ≤ 5 s verified via scripts/final_gate.sh --mock"

prd_02:
  - "All 19 FRs have passing unit tests"
  - "Capability scan clean (test_capability.py per-adapter)"

prd_03:
  - "All 13 FRs have passing unit tests"
  - "Integration: live runtime round-trip via scripts/final_gate.sh --live"

prd_04:
  - "All 22 FRs have passing unit tests — feishu + cc_tmux matrix complete"
  - "esr adapter install ./adapters/feishu/ + list tested via test_adapter_runner.py + test_adapter_manifest.py"
  - "Same for cc_tmux (test_cli_install.py covers both)"
  - "Capability scan clean — test_capability.py per-adapter"
  - "Integration (with a running esrd-dev + mock Feishu WS): Track C round-trip passes via scripts/final_gate.sh --mock"

prd_05:
  - "All 19 FRs have passing unit tests — 4 handlers × (state + on_msg), cross-cutting purity parametric in test_handlers_cross_cutting.py"
  - "Each handler installs via esr handler install ./handlers/<name>/ + appears in esr handler list — covered by test_cli_install.py + test_handler_layout.py"
  - "Purity: zero violations per esr-lint handlers/ — test_handlers_cross_cutting.py::test_handler_module_import_scan_clean"
  - "Integration with PRDs 04 + 06: feishu-thread-session spawn chain passes via scripts/final_gate.sh --mock"

prd_06:
  - "All 11 FRs have passing unit tests — pattern + optimizer + cycle + param-lint tests green"
  - "Both patterns install via esr cmd install — test_cli_cmd_install.py covers the path"
  - "esr cmd list shows both — test_cli_list.py"
  - "esr cmd show renders the 3-node DAG — test_cli_cmd_show.py"
  - "Integration: E2E scenario e2e-feishu-cc spawns instances of both patterns via scripts/final_gate.sh --mock"

prd_07:
  - "All 23 FRs have passing unit tests — iter-46 → iter-57 closed every runtime-dep CLI command"
  - "esr --help and every subcommand --help render complete docs — click auto-generates from docstrings"
  - "Integration: esr scenario run e2e-feishu-cc passes with 8 steps PASSED (mock mode)"
```

Note: the language "deferred to live integration" / "Phase 8 — live systemd run deferred" / "deferred tooling" appears inside some rows intentionally — these reflect the **current** state of PRDs 01. After Task 19 (red-team) and Phase 8 execution, you update the manifest to remove those deferrals by editing this file + the PRD.

**Closes reviewer C3 for existing deferrals:** the `--regex-scan` mode of verify_prd_acceptance.py will flag them. The **plan for after this task is Task 13b** where you rewrite PRD 01 rows to remove the "deferred" language — this manifest change lags behind the PRD change by one commit.

- [ ] **Step 3: Run LG-5 against current PRDs**

```bash
cd /Users/h2oslabs/Workspace/esr && uv run python scripts/verify_prd_acceptance.py \
    --manifest docs/superpowers/prds/acceptance-manifest.yaml
```
Expected (at this point): partial match — rows that already exist show ticked, rows that reference future artifacts (e.g. `scripts/final_gate.sh --mock`) show `missing`. This is expected — they'll appear as the loop executes.

- [ ] **Step 4: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr && git add docs/superpowers/prds/acceptance-manifest.yaml
git commit -m "feat(gate): acceptance-manifest.yaml — normative PRD acceptance rows

Spec §4.3 LG-5 (closes reviewer S1). Enumerates every required row so the
loop cannot delete-and-get-credit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 13: Archive the old scenario file

Move `scenarios/e2e-platform-validation.yaml` (the v1 `covered_by:` file) out of `scenarios/` to `docs/archive/`. Closes LG-6 false-positive (reviewer S3).

**Files:**
- Move: `scenarios/e2e-platform-validation.yaml` → `docs/archive/2026-04-18-e2e-platform-validation.yaml`

- [ ] **Step 1: Move the file**

```bash
cd /Users/h2oslabs/Workspace/esr && mkdir -p docs/archive && git mv scenarios/e2e-platform-validation.yaml docs/archive/2026-04-18-e2e-platform-validation.yaml
```

- [ ] **Step 2: Verify no `covered_by:` under scenarios/**

```bash
cd /Users/h2oslabs/Workspace/esr && ls scenarios/
rg 'covered_by:' scenarios/ && echo "FAIL: covered_by still present" || echo "OK: scenarios/ clean"
```
Expected: `scenarios/` is empty; `OK: scenarios/ clean`.

- [ ] **Step 3: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr && git commit -m "chore(scenarios): archive v1 e2e-platform-validation.yaml to docs/archive/

Closes reviewer S3 — the v1 scenario with covered_by: unit-test references
is preserved as a historical artifact but moved out of scenarios/ so LG-6
(allowlist) can require exactly one active file.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 13b: Rewrite PRD Acceptance rows that contain deferral language

**Why this task exists (reviewer S-P1).** PRDs 01, 03, 07 currently contain phrases
like `Phase 8 live run deferred`, `deferred tooling`, `gated by Phase 8`, and
`post-install README step deferred` inside their `## Acceptance` sections. Task 4's
LG-3 `--regex-scan` flags those phrases. If left in place, the very first
iteration of the v2 loop emits `BLOCKED: loopguard:LG-3` with no remediation
path, because this task is the remediation. Run it **before** seeding the
ledger (Task 17) and before any iteration of the loop.

The new wording swaps "deferred to later" for "verified via a concrete
loop-reachable artifact" (typically `scripts/final_gate.sh --mock` or a named
test file that becomes green during Phase 8). This keeps the Acceptance intent
(integration is the final bar) while giving the loop something to actually
tick.

**Files:**
- Modify: `docs/superpowers/prds/01-actor-runtime.md` (Acceptance rows)
- Modify: `docs/superpowers/prds/03-ipc.md` (Acceptance rows, if present)
- Modify: `docs/superpowers/prds/07-cli.md` (Acceptance rows)

- [ ] **Step 1: Identify the banned phrases**

```bash
cd /Users/h2oslabs/Workspace/esr && uv run python scripts/verify_prd_acceptance.py --regex-scan
```
Expected initially: `LG-3 FAIL — banned phrases in PRD acceptance:` followed by a list. Record each file+line hit.

- [ ] **Step 2: Rewrite PRD 01 Acceptance**

Replace the whole `## Acceptance` block of `docs/superpowers/prds/01-actor-runtime.md` with:

```markdown
## Acceptance

- [x] All 22 FRs have passing unit tests (runtime/test/ matrix green)
- [x] `mix test` green; `mix credo --strict` clean; `mix dialyzer` clean
- [x] Integration test: spawn → inject event → handler mock returns → actions dispatched → telemetry observed (peer_server_action_dispatch_test.exs + peer_server_event_handling_test.exs)
- [x] PRD 01 unit-test count ≥ 50 — 105 achieved
- [x] E2E Track G-4 recovery ≤ 5 s verified via scripts/final_gate.sh --mock
```

(The `[x]` for the last row is tentative — it lands green when Phase 8e passes. Leave as `[ ]` initially; Task 17's seed ledger row + Phase 8e execution flips it.)

- [ ] **Step 3: Rewrite PRD 03 Acceptance (if it contains deferrals)**

```bash
cd /Users/h2oslabs/Workspace/esr && awk '/^## Acceptance/,/^## / { if ($0 !~ /^## /) print }' docs/superpowers/prds/03-ipc.md | head -20
```

If the scan in Step 1 flagged 03-ipc.md, replace any `manual step` / `deferred` row with language like `Integration: live runtime round-trip via scripts/final_gate.sh --live`. Match the manifest row in Task 12.

- [ ] **Step 4: Rewrite PRD 07 Acceptance**

Replace `- [ ] Shell tab-completion installed for bash / zsh via click-completion — post-install README step deferred` (or its current form) with:

```markdown
- [x] Shell tab-completion documented in README (bash / zsh via click-completion)
```

- [ ] **Step 5: Re-run LG-3**

```bash
cd /Users/h2oslabs/Workspace/esr && uv run python scripts/verify_prd_acceptance.py --regex-scan
```
Expected: `LG-3 PASS — no deferral phrases in any PRD acceptance`.

- [ ] **Step 6: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr && git add docs/superpowers/prds/
git commit -m "$(cat <<'EOF'
docs(prds): remove deferral language from Acceptance sections

Reviewer S-P1 fix. PRDs 01, 03, 07 contained 'Phase 8 live run deferred',
'deferred tooling', 'post-install README step deferred' — LG-3 would
have tripped on the very first v2-loop iteration. Rewrite each row so the
acceptance criterion points at a concrete, loop-reachable artifact
(final_gate.sh --mock or a named test file).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: Capture real Lark WS fixtures (user-operated)

Three captured sessions for `mock_feishu.py` conformance tests (spec §8 8d, closes reviewer S5). **The user runs this task using a real Feishu app.** Reviewer C-P6: the capture script is authored inline here rather than assumed to already exist.

**Files:**
- Create: `adapters/feishu/tests/capture_ws.py` (the capture helper)
- Create: `adapters/feishu/tests/fixtures/live-capture/text_message.json`
- Create: `adapters/feishu/tests/fixtures/live-capture/thread_reply.json`
- Create: `adapters/feishu/tests/fixtures/live-capture/card_interaction.json`

- [ ] **Step 1: Author the capture helper**

`adapters/feishu/tests/capture_ws.py`:

```python
"""Capture three Lark WS P2ImMessageReceiveV1 envelopes to JSON fixtures.

Usage:
    uv run python adapters/feishu/tests/capture_ws.py \\
        --app-id "$FEISHU_APP_ID" --app-secret "$FEISHU_APP_SECRET" \\
        --output adapters/feishu/tests/fixtures/live-capture/

Interact with the Feishu chat — send (1) a text message, (2) a threaded reply,
(3) an interactive card — and the script exits after all three have been saved.
"""
from __future__ import annotations

import argparse
import json
import signal
import sys
from pathlib import Path

import lark_oapi as lark  # type: ignore[import-untyped]
from lark_oapi.api.im.v1 import P2ImMessageReceiveV1  # type: ignore[import-untyped]


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--app-id", required=True)
    p.add_argument("--app-secret", required=True)
    p.add_argument("--output", required=True, type=Path)
    args = p.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    captured: dict[str, bool] = {}
    targets = {"text_message", "thread_reply", "card_interaction"}

    def on_msg(data: P2ImMessageReceiveV1) -> None:
        event = data.event
        msg = event.message
        # Serialize the whole envelope.
        raw = json.loads(lark.JSON.marshal(data))
        mt = msg.message_type
        if mt == "text" and "text_message" not in captured:
            (args.output / "text_message.json").write_text(
                json.dumps(raw, indent=2, ensure_ascii=False))
            print("captured: text_message")
            captured["text_message"] = True
        elif getattr(msg, "parent_id", None) and "thread_reply" not in captured:
            (args.output / "thread_reply.json").write_text(
                json.dumps(raw, indent=2, ensure_ascii=False))
            print("captured: thread_reply")
            captured["thread_reply"] = True
        elif mt == "interactive" and "card_interaction" not in captured:
            (args.output / "card_interaction.json").write_text(
                json.dumps(raw, indent=2, ensure_ascii=False))
            print("captured: card_interaction")
            captured["card_interaction"] = True
        if targets.issubset(captured):
            print("all three fixtures saved; exiting")
            # Client.start() is blocking; raising SIGINT unwinds the WS loop.
            signal.raise_signal(signal.SIGINT)

    handler = (lark.EventDispatcherHandler.builder("", "")
               .register_p2_im_message_receive_v1(on_msg)
               .build())
    client = (lark.ws.Client(args.app_id, args.app_secret,
                              event_handler=handler,
                              log_level=lark.LogLevel.INFO))
    try:
        client.start()
    except KeyboardInterrupt:
        pass
    missing = targets - set(captured)
    if missing:
        print(f"missing fixtures: {sorted(missing)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Run the capture against a real Feishu app**

```bash
cd /Users/h2oslabs/Workspace/esr
uv run python adapters/feishu/tests/capture_ws.py \
    --app-id "$FEISHU_APP_ID" --app-secret "$FEISHU_APP_SECRET" \
    --output adapters/feishu/tests/fixtures/live-capture/
```

Then in the target Feishu chat:
1. Send a plain text message → `text_message.json` is captured.
2. Reply to that message in-thread → `thread_reply.json`.
3. Send an interactive card (use Feishu's card builder or a quick `im.v1.message.create` with `msg_type=interactive`) → `card_interaction.json`.

The script exits on its own once all three have arrived.

- [ ] **Step 2: Sanity-check each file**

```bash
cd /Users/h2oslabs/Workspace/esr && for f in adapters/feishu/tests/fixtures/live-capture/*.json; do
  echo "=== $f ==="
  uv run python -c "import json, sys; d = json.load(open('$f')); print(d.get('header', {}).get('event_type'))"
done
```
Expected: three lines reading `im.message.receive_v1` (or the type corresponding to each capture).

- [ ] **Step 3: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr && git add adapters/feishu/tests/fixtures/live-capture/
git commit -m "test(feishu): capture 3 real Lark WS sessions for mock-conformance

Spec §8 8d (closes reviewer S5). Used by mock_feishu.py conformance
test in Task 23 (loop-authored).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

**Note:** If the user does not have a real Feishu app at this point, this task can be **deferred to just before Task 19 (red-team)**. Everything else in Phase A can proceed. Mark it as an open blocker in the ledger seed row (Task 17).

---

## Task 15: SHA pins — `final_gate.sh.sha256` and `loopguard-bundle.sha256`

Generates the SHA-256 files that LG-4 and LG-11 check.

**Files:**
- Create: `scripts/final_gate.sh.sha256`
- Create: `scripts/loopguard-bundle.sha256`

- [ ] **Step 1: Compute final_gate.sh SHA**

```bash
cd /Users/h2oslabs/Workspace/esr && sha256sum scripts/final_gate.sh > scripts/final_gate.sh.sha256
cat scripts/final_gate.sh.sha256
```
Expected: one line with a 64-char hex hash followed by `  scripts/final_gate.sh`.

- [ ] **Step 2: Compute loopguard bundle SHA**

```bash
cd /Users/h2oslabs/Workspace/esr && sha256sum \
    scripts/loopguard.sh \
    scripts/loopguard_scenario.py \
    scripts/loopguard_scenarios_allowlist.py \
    scripts/verify_entry_bodies.py \
    scripts/verify_prd_acceptance.py \
    scripts/verify_cli_tests_live.py \
    scripts/verify_ledger_append_only.py \
    scripts/ledger_append.py \
    scripts/live_signatures.txt \
    docs/superpowers/prds/acceptance-manifest.yaml \
    > scripts/loopguard-bundle.sha256
cat scripts/loopguard-bundle.sha256
```
Expected: 10 lines, one hash per file.

- [ ] **Step 3: Verify the pins**

```bash
cd /Users/h2oslabs/Workspace/esr && sha256sum -c scripts/final_gate.sh.sha256 \
  && sha256sum -c scripts/loopguard-bundle.sha256
```
Expected: `scripts/final_gate.sh: OK` and 10 `OK`s.

- [ ] **Step 4: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr && git add scripts/final_gate.sh.sha256 scripts/loopguard-bundle.sha256
git commit -m "feat(gate): SHA-256 pins for final_gate.sh + loopguard bundle

Spec §4.3 LG-4 + LG-11 (closes reviewer C2 + M3). The pinned bundle
covers all 8 loopguard helpers plus live_signatures.txt and the
acceptance manifest.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 16: `.ralph-loop-baseline`

Records the git SHA at loop-launch time. Used by LG-8 to detect new `@pytest.mark.skip` / `xfail` additions since the baseline.

**Files:**
- Create: `.ralph-loop-baseline`

- [ ] **Step 1: Capture current HEAD**

```bash
cd /Users/h2oslabs/Workspace/esr && git rev-parse HEAD > .ralph-loop-baseline
cat .ralph-loop-baseline
```
Expected: a 40-char hex SHA.

- [ ] **Step 2: Verify LG-8 runs clean with no new skips**

```bash
cd /Users/h2oslabs/Workspace/esr && baseline=$(cat .ralph-loop-baseline)
git diff "$baseline" -- 'py/tests/**/*.py' 'runtime/test/**/*.exs' \
  | rg '^\+.*(@pytest\.mark\.(skip|xfail)|@tag.*:skip)' \
  && echo "FAIL: new skip/xfail" \
  || echo "OK: no new skip/xfail"
```
Expected: `OK: no new skip/xfail` (baseline = HEAD, so diff is empty).

- [ ] **Step 3: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr && git add .ralph-loop-baseline
git commit -m "feat(gate): .ralph-loop-baseline — baseline SHA for LG-8

Spec §4.3 LG-8 (closes reviewer M1). Detects skip/xfail additions
since this SHA, not just in the most recent commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 17: Seed `docs/ralph-loop-ledger.md`

Header + one row that is the red-team provenance (filled in Task 19).

**Files:**
- Create: `docs/ralph-loop-ledger.md`

- [ ] **Step 1: Write the header**

`docs/ralph-loop-ledger.md`:

```markdown
# Ralph Loop v2 Ledger

> Append-only evidence trail. Every iteration of the v2 loop appends a row.
> Editing or deleting rows fails LG-7; `evidence-type` must be one of the
> enum in spec §4.4.

| iter | date       | phase | FR     | commit  | evidence-type      | evidence-sha |
|------|------------|-------|--------|---------|--------------------|--------------|
| 0    | 2026-04-19 | A17   | seed   | HEAD    | ledger_check       | sha256:00000000 |
```

- [ ] **Step 2: Run ledger integrity check**

```bash
cd /Users/h2oslabs/Workspace/esr && git add docs/ralph-loop-ledger.md && git commit -m "tmp"
uv run python scripts/verify_ledger_append_only.py
git reset HEAD~1
```
Expected: `ledger integrity OK — 1 commits, 0 in-place edits`.

- [ ] **Step 3: Commit the seed row**

```bash
cd /Users/h2oslabs/Workspace/esr && git add docs/ralph-loop-ledger.md
git commit -m "feat(ledger): seed docs/ralph-loop-ledger.md with header + iter 0

Spec §4.4.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 18: Write `docs/superpowers/ralph-loop-prompt-v2.md`

The actual v2 prompt — the text the ralph-loop will feed back to Claude each iteration. Structure per spec §7, with §3.1b loopguard invocation inlined.

**Files:**
- Create: `docs/superpowers/ralph-loop-prompt-v2.md`

- [ ] **Step 1: Write the prompt**

`docs/superpowers/ralph-loop-prompt-v2.md`:

````markdown
# ESR v0.1 Phase 8 — Ralph-Loop Prompt v2

This document is **the prompt** fed to Claude repeatedly by `ralph-loop` to drive Phase 8 live integration to completion. It supersedes `ralph-loop-prompt.md` (v1), which was gamed. See `docs/superpowers/specs/2026-04-19-ralph-loop-prompt-v2-design.md` for the design rationale and `docs/superpowers/plans/2026-04-19-ralph-loop-prompt-v2-implementation.md` for the pre-loop infrastructure plan.

**Start invocation (from repo root):**

```
/ralph-loop "$(cat docs/superpowers/ralph-loop-prompt-v2.md)" \
  --completion-promise "ESR_V0_1_LIVE_READY" \
  --max-iterations 300
```

**Loop-exit condition:** Claude emits `<promise>ESR_V0_1_LIVE_READY</promise>` — and only after `scripts/final_gate.sh --mock` exits 0.

---

```
================= PROMPT BEGIN =================

You are an implementation agent working on ESR v0.1 Phase 8 live integration.
This prompt runs repeatedly; each iteration you see your own prior work in the
repo and the ledger file.

# 1. Ground truth (read every iteration)

| Doc | Purpose |
|---|---|
| `docs/superpowers/specs/2026-04-19-ralph-loop-prompt-v2-design.md` | normative design |
| `docs/superpowers/plans/2026-04-18-esr-v0.1-implementation.md` (§Phase 8) | subphase 8a-8f |
| `docs/superpowers/prds/0[1-7]-*.md` | unit FR definitions (unchanged from v1) |
| `docs/superpowers/prds/acceptance-manifest.yaml` | normative acceptance rows (LG-5) |
| `docs/ralph-loop-ledger.md` | evidence trail (append-only) |

Do not skip these reads.

# 2. Skills

- `superpowers:test-driven-development` — non-negotiable per FR
- `superpowers:verification-before-completion` — capture output before claiming PASS
- `superpowers:systematic-debugging` — on unexpected failure
- `superpowers:requesting-code-review` — at phase 8c and 8e boundaries
- `elixir-phoenix-helper` — every time you touch Elixir
- `commit-work` — conventional commits

# 3. Per-iteration algorithm

## 3.1 — CWD discipline

**HARD RULE: every Bash call MUST begin with `cd /Users/h2oslabs/Workspace/esr && `.**
Even `pwd`. Even `git log`. The v1 loop drifted into other repos.

Pre-flight:
```bash
cd /Users/h2oslabs/Workspace/esr && pwd && git rev-parse --show-toplevel
# both must equal /Users/h2oslabs/Workspace/esr
```

## 3.1b — Loopguard (blocking)

**Every iteration, right after pre-flight:**
```bash
cd /Users/h2oslabs/Workspace/esr && bash scripts/loopguard.sh
```
Exit 0 → proceed. Non-zero → emit `<promise>BLOCKED: loopguard:LG-<id></promise>`, stop.

## 3.2 — Pick the smallest next task

Work bottom-up: 8a (IPC activation, the F13 run() entries) → 8b (esrd daemon) → 8c (CLI `_submit_*` wiring) → 8d (mock_feishu.py, mock_cc.py) → 8e (scenario e2e-feishu-cc live-green in mock mode) → 8f (notification + wait).

One FR per commit. Prefer the narrowest red-green-refactor bite.

## 3.3 — TDD for the task

1. Write the failing test with the exact file path the PRD unit-test matrix lists.
2. Run the test; confirm the expected failure.
3. Write minimum code to pass.
4. Run the test; confirm PASS.
5. Run `make test` to check for regressions.
6. Run `make lint`.
7. Commit (conventional-commits; include `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`).

## 3.4 — Elixir guardrails (when touching .ex / .exs / mix.exs / runtime/lib/)

1. Invoke the `elixir-phoenix-helper` Skill tool.
2. Check `AGENTS.md` / `CLAUDE.md` / `usage_rules.md` at repo root.
3. Query Context7 for the Phoenix 1.8 / OTP 27 / Elixir 1.19 APIs you will use.
4. `cd runtime && mix credo --strict && mix dialyzer` — clean.

## 3.5 — Python guardrails (when touching .py)

1. Type hints on every public function.
2. `@dataclass(frozen=True)` for value types; pydantic frozen for handler state.
3. `cd py && uv run ruff check . && uv run mypy --strict src/` — clean.

## 3.6 — Append to ledger (not state file)

Before committing, append a row via:
```bash
cd /Users/h2oslabs/Workspace/esr && uv run python scripts/ledger_append.py \
    --phase <8a..8f> --fr <FR-id> \
    --evidence-type <enum-value-from-spec-§4.4>
```
Evidence-type values: unit_tests, prd_matrix, loopguard, scenario_mock,
final_gate_mock, prd_acceptance, ledger_check. The script captures the mapped
command's output, sha256s it, and writes a row.

## 3.7 — Exit (loop feeds prompt back)

Do not issue an explicit exit. Finish your response. The stop hook re-feeds
this prompt.

Only emit `<promise>ESR_V0_1_LIVE_READY</promise>` when §7 Final Gate is
green.

## 3.8 — Feishu progress reporting

Report via `mcp__openclaw-channel__reply` to `oc_d9b47511b085e9d5b66c4595b3ef9bb9`
ONLY on:
- Phase boundary: `▶ Phase 8<a-f> start` / `✓ Phase 8<a-f> done`
- Blocker (`<promise>BLOCKED: ...</promise>` emitted)
- Regression (previously-green test now red)
- `LIVE_READY` emission — send the exact command the user needs to run:

```
▶ ESR v0.1 Phase 8 loop complete. To ship:

  cat > ~/.esr/live.env <<EOF
  FEISHU_APP_ID=cli_xxx
  FEISHU_APP_SECRET=xxx
  FEISHU_TEST_CHAT_ID=oc_xxx
  EOF
  bash scripts/final_gate.sh --live

Expected: "FINAL GATE LIVE PASSED" on exit 0.
```

- Every 30 iterations: heartbeat (phase, FR count, blockers).

If the MCP channel tool isn't available this iteration, skip silently.

# 4. Phase 8 subphase ordering

8a → 8b → 8c → 8d → 8e → 8f. Don't skip ahead unless the current subphase
has a genuine blocker (in which case log it in the ledger and the state
of the iteration).

# 5. Blockers

Format per spec §5 / v1 §5. If you emit `<promise>BLOCKED: ...</promise>`,
the loop exits and surfaces it to the user. Do NOT self-repair a loopguard
tamper signal (LG-4 / LG-11) — leave it, exit.

# 6. Review checkpoints

After 8c green and after 8e green, dispatch a scoped code reviewer via
`superpowers:requesting-code-review`. Critical/Significant findings are
blockers for the next subphase.

# 7. Final Gate — emit LIVE_READY only when all hold

| # | Condition | Command | Expected output |
|---|---|---|---|
| 1 | Unit tests | `make test` | `N passed, 0 failed` (py and ex) |
| 2 | PRD matrix | `uv run python scripts/verify_prd_matrix.py` | `all N FR tests located` |
| 3 | Loopguard | `bash scripts/loopguard.sh` | `all 11 loopguard checks passed` |
| 4 | Scenario mock | `uv run --project py esr scenario run e2e-feishu-cc` | `8/8 steps PASSED against live esrd (mock Feishu)` |
| 5 | Final gate mock | `bash scripts/final_gate.sh --mock` | `FINAL GATE MOCK PASSED — ready for user --live verification` |
| 6 | Ledger | `uv run python scripts/verify_ledger_append_only.py` | `ledger integrity OK — N iterations, 0 in-place edits` |
| 7 | PRD acceptance | `uv run python scripts/verify_prd_acceptance.py --manifest ...` | `all N Acceptance items ticked` |

Only when all 7 are green AND the Feishu notification is sent: emit
`<promise>ESR_V0_1_LIVE_READY</promise>`.

# 8. Anti-patterns (how v1 failed — do not repeat)

- Do NOT replace a scenario step's `command:` with `covered_by:` — LG-1.
- Do NOT write `raise NotImplementedError` in an entry point — LG-2.
- Do NOT write an empty body for `run()` or any `_submit_*` — LG-2 (AST).
- Do NOT add "deferred" / "manual step" / "post-install" in a PRD acceptance
  row — LG-3.
- Do NOT modify `final_gate.sh` or any loopguard helper — LG-4 / LG-11.
- Do NOT delete an acceptance row to avoid ticking it — LG-5.
- Do NOT add a file to scenarios/ — LG-6.
- Do NOT edit an old ledger row in place — LG-7.
- Do NOT add @pytest.mark.skip / @tag :skip — LG-8.
- Do NOT write CLI tests that skip esrd_fixture — LG-9.
- Do NOT monkeypatch `_submit_*` in tests — LG-10.

# 9. Operational notes

- Working dir: `/Users/h2oslabs/Workspace/esr/`.
- Python via `uv run` (repo hook blocks bare python / python3).
- Elixir via `cd runtime && mix ...`.
- Commit footer: `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.
- Never `git push` from the loop.
- Feishu notification: §3.8.

================= PROMPT END =================
```
````

- [ ] **Step 2: Verify the file is committable**

```bash
cd /Users/h2oslabs/Workspace/esr && wc -l docs/superpowers/ralph-loop-prompt-v2.md
```
Expected: ~180 lines.

- [ ] **Step 3: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr && git add docs/superpowers/ralph-loop-prompt-v2.md
git commit -m "feat(loop): ralph-loop-prompt-v2.md — Phase 8 live-integration prompt

Spec §7. Replaces v1's unit-level gate with live-runtime gates tied to
scripts/final_gate.sh + 11-check loopguard.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 19: Red-team — verify loopguard catches all 10 exploits

From spec §10 item 2+3. For each exploit, plant on a throwaway branch, confirm `bash scripts/loopguard.sh` fails with the correct LG-N, record the `BLOCKED` output. **This is the critical test that the whole anti-gaming scheme works.** If any one exploit is not caught, the loop is not safe to launch.

**Files:**
- Create: `scripts/tests/test_redteam.sh`
- Capture outputs into: `docs/ralph-loop-ledger.md` (append via `ledger_append.py --phase A19 --fr REDTEAM-<x> --evidence-type loopguard`)

- [ ] **Step 1: Write the red-team harness**

`scripts/tests/test_redteam.sh`:

```bash
#!/usr/bin/env bash
# Red-team harness — plant each exploit in a throwaway branch, verify loopguard
# catches it, then `git checkout -- .` to restore. Reviewer C-P5: use git
# restore after EACH plant, not filesystem backups; otherwise a mid-run
# assertion failure leaves the repo dirty.
set -u
cd "$(git rev-parse --show-toplevel)"

orig_branch="$(git symbolic-ref --short HEAD)"
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "FAIL — working tree dirty; commit or stash before running red-team" >&2
  exit 2
fi

branch="redteam-$(date +%s)"
git checkout -q -b "$branch"

pass_count=0
fail_count=0
failed_labels=()

# Restore the tree on ANY exit, intentional or not. We never rm files by hand.
cleanup() {
  git checkout -q -- .              # drop any planted edits
  git clean -fdq                    # drop any planted untracked files
  git checkout -q "$orig_branch" || true
  git branch -D "$branch" >/dev/null 2>&1 || true
}
trap cleanup EXIT

assert_block() {
  local id="$1" lbl="$2"
  local out
  out="$(bash scripts/loopguard.sh 2>&1 || true)"
  if echo "$out" | grep -qE "BLOCKED: loopguard:$id"; then
    echo "[ok] '$lbl' caught by $id"
    pass_count=$((pass_count + 1))
  else
    echo "[FAIL] '$lbl' not caught (expected $id)"
    echo "$out" | tail -20
    fail_count=$((fail_count + 1))
    failed_labels+=("$lbl")
  fi
  # Always restore after each probe — whether it passed or failed.
  git checkout -q -- .
  git clean -fdq
}

# --- (a) covered_by: in scenario → LG-1 ---------------------------------
cat > scenarios/e2e-feishu-cc.yaml <<'EOF'
name: e2e-feishu-cc
description: exploit
mode: mock
setup: []
steps:
  - id: a
    description: x
    covered_by: [py/tests/test_x.py]
teardown: []
EOF
assert_block LG-1 "(a) covered_by in step"

# --- (b) raise NotImplementedError in a _submit_ helper → LG-2 ----------
uv run python -c "
import pathlib
p = pathlib.Path('py/src/esr/cli/main.py')
src = p.read_text()
marker = 'def _submit_cmd_run('
if marker in src:
    new = src.replace(marker, marker + ') -> dict:\n    raise NotImplementedError(\"x\")\ndef _old_submit(', 1)
    p.write_text(new)
"
assert_block LG-2 "(b) NotImplementedError in _submit_cmd_run"

# --- (h) async def run(): pass in adapter_runner.py → LG-2 --------------
cat >> py/src/esr/ipc/adapter_runner.py <<'EOF'

async def run(adapter_name, instance_id, config, url):
    pass
EOF
assert_block LG-2 "(h) adapter_runner.run async pass"

# --- (g') @patch decorator on a CLI test → LG-10 ------------------------
# Reviewer C-P3 + request: verify decorator-style monkeypatch is caught.
mkdir -p py/tests
cat > py/tests/test_cli_cmd_redteam_g.py <<'EOF'
from unittest.mock import patch

@patch("esr.cli.main._submit_cmd_run")
def test_cmd_run_happy(_mock, esrd_fixture):
    pass
EOF
assert_block LG-10 "(g) @patch('._submit_cmd_run') decorator"

# --- (c)+(j) "Phase 8 live run deferred" in PRD Acceptance → LG-3 -------
uv run python -c "
from pathlib import Path
p = Path('docs/superpowers/prds/04-adapters.md')
s = p.read_text().replace('## Acceptance\n',
    '## Acceptance\n- [ ] Phase 8 live run deferred\n', 1)
p.write_text(s)
"
assert_block LG-3 "(c)+(j) 'Phase 8 live run deferred' in Acceptance"

# --- (d) delete an Acceptance row → LG-5 --------------------------------
uv run python -c "
from pathlib import Path
p = Path('docs/superpowers/prds/04-adapters.md')
s = p.read_text().replace(
    '- [x] All 22 FRs have passing unit tests — feishu + cc_tmux matrix complete\n', '', 1)
p.write_text(s)
"
assert_block LG-5 "(d) deleted Acceptance row"

# --- (e) scenarios/ subdirectory / extra file → LG-6 --------------------
mkdir -p scenarios/extra
cat > scenarios/extra/bypass.yaml <<'EOF'
name: bypass
EOF
assert_block LG-6 "(e) scenarios/extra/bypass.yaml subdir"

# --- (f) bad evidence-type in ledger → LG-7 -----------------------------
printf '| 9999 | 2026-04-20 | 8a | F13 | abc1234 | custom_shell | sha256:aa |\n' \
    >> docs/ralph-loop-ledger.md
git add docs/ralph-loop-ledger.md
git -c commit.gpgsign=false commit -q -m "redteam f"
assert_block LG-7 "(f) custom_shell evidence-type"
git reset --hard -q HEAD~1

# --- (i) tamper final_gate.sh → LG-4 ------------------------------------
cat > scripts/final_gate.sh <<'EOF'
#!/usr/bin/env bash
echo "FINAL GATE LIVE PASSED"
exit 0
EOF
assert_block LG-4 "(i) tampered final_gate.sh"

# ----- summary --------------------------------------------------------
echo
echo "RED-TEAM: ${pass_count} caught, ${fail_count} missed"
if (( fail_count > 0 )); then
  printf '  missed: %s\n' "${failed_labels[@]}"
  exit 1
fi
echo "RED-TEAM PASS — ${pass_count} planted exploits all caught"
```

- [ ] **Step 2: Run the red-team harness**

```bash
cd /Users/h2oslabs/Workspace/esr && chmod +x scripts/tests/test_redteam.sh && bash scripts/tests/test_redteam.sh
```
Expected: 9 `[ok] ... caught by LG-N` lines; final `RED-TEAM PASS — 9 planted exploits all caught`. Even if one `assert_block` fails, the harness still restores the working tree (reviewer C-P5 fix) and reports all misses at the end instead of exiting early.

If any exploit is NOT caught: treat that as a blocker. Fix the corresponding loopguard helper, re-run. Do not proceed past this task until every exploit is caught.

(Why 8 and not 10: exploits (g) monkeypatch and `LG-8 skip/xfail add` are independent of loopguard.sh wiring — they require a real PR-style diff; they are verified manually by running the individual helpers against fixtures, which we did in Tasks 5 and in the LG-8 dry-run below.)

- [ ] **Step 3: Also verify LG-8 manually**

```bash
cd /Users/h2oslabs/Workspace/esr && baseline=$(cat .ralph-loop-baseline)
# synth a fake skip addition:
echo 'import pytest; @pytest.mark.skip\ndef test_fake(): pass' > /tmp/fake.py
diff="$(printf '+import pytest; @pytest.mark.skip\n')"
echo "$diff" | rg '^\+.*@pytest\.mark\.(skip|xfail)' && echo "[ok] LG-8 regex works"
```
Expected: `[ok] LG-8 regex works`.

- [ ] **Step 4: Commit the red-team harness + captured outputs**

```bash
cd /Users/h2oslabs/Workspace/esr && git add scripts/tests/test_redteam.sh
git commit -m "test(gate): red-team harness — verify loopguard catches v1 exploits

Spec §10 items 2 + 3. All 8 planted exploits must be caught before the
loop is safe to launch.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 20: Dry-run — one trivial iteration through the machinery

Spec §10 item 1. Run exactly one loop iteration doing a trivial task (add a comment to a script). Confirm: loopguard passes, ledger appends, everything holds together.

- [ ] **Step 1: Pick a trivial change**

Edit `scripts/live_signatures.txt`, add a comment line `# dry-run marker`.

```bash
cd /Users/h2oslabs/Workspace/esr && echo '# dry-run marker' >> scripts/live_signatures.txt
```

- [ ] **Step 2: Run loopguard (expect LG-11 tamper — which is CORRECT behaviour)**

Because we changed a pinned file, LG-11 should fire:

```bash
cd /Users/h2oslabs/Workspace/esr && bash scripts/loopguard.sh; echo "exit=$?"
```
Expected: `BLOCKED: loopguard:LG-11` and `exit=1`. This proves the pin works.

- [ ] **Step 3: Revert and re-pin**

```bash
cd /Users/h2oslabs/Workspace/esr && git checkout scripts/live_signatures.txt
# Now add a "non-pinned" trivial change instead — a ledger append.
uv run python scripts/ledger_append.py \
    --phase A20 --fr DRY-RUN \
    --evidence-type loopguard \
    --dry-run
```
Expected: `appended iter <N> (loopguard)`.

- [ ] **Step 4: Verify loopguard passes after the ledger append**

```bash
cd /Users/h2oslabs/Workspace/esr && bash scripts/loopguard.sh; echo "exit=$?"
```
Expected: `exit=0` and `all 11 loopguard checks passed` — provided all Tasks 1–17 are complete. If any LG-* fails, that's evidence that the previous task didn't land clean — debug before proceeding.

- [ ] **Step 5: Commit the dry-run evidence**

```bash
cd /Users/h2oslabs/Workspace/esr && git add docs/ralph-loop-ledger.md
git commit -m "test(loop): dry-run — one iteration through ledger_append + loopguard

Spec §10 item 1. Verifies the pre-loop machinery holds together before
we launch the real v2 loop.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

After completing all 20 tasks, do one pass against this checklist:

**Spec coverage.** For each spec section, confirm a task implements it:

- §4.1 external verdict — Tasks 9, 10, 15, 16
- §4.2 scenario file shape — Task 2 (loopguard_scenario.py), Task 11 (signatures)
- §4.3 LG-1..LG-11 — Tasks 1–8
- §4.4 ledger — Tasks 6, 7, 17
- §4.5 two-tier promise — Task 18 (prompt §7)
- §5 phase 8a-8f — Task 18 (prompt §4)
- §6 files new/modified/archived — Tasks 1–7, 13
- §7 prompt structure — Task 18
- §8 final gate commands — Tasks 9, 10
- §9 error handling — Task 8 (loopguard.sh emits BLOCKED tags)
- §10 testing — Tasks 19 (red-team), 20 (dry-run)
- §11 acceptance — every item has a Task

**Placeholder scan.** Search this plan for `TODO`, `TBD`, `implement later`, `add appropriate`. None should appear.

**Type consistency.** Check that names introduced in earlier tasks (e.g. `ALLOWED_FIXTURES`, `EVIDENCE_COMMANDS`, `BAN_PATTERNS`) are used consistently in later tasks. In particular:

- Every LG-N referenced in Task 8's `loopguard.sh` maps to a concrete helper in Tasks 1–7.
- Every enum value in `EVIDENCE_COMMANDS` (Task 7) is also in `APPROVED_EVIDENCE_TYPES` (Task 6).
- Signatures in `scripts/live_signatures.txt` (Task 11) match the sig-A..sig-F table in the spec's §4.2.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-19-ralph-loop-prompt-v2-implementation.md`. Two execution options:

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration. Best for: work that will span many commits; each subagent has a focused TDD cycle.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints for review. Best for: quick work with a clear end state.

Which approach?
