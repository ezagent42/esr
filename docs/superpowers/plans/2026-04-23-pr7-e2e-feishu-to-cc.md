# PR-7 End-to-End Feishu-to-CC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver three bash e2e scripts + the production-code hooks they need (adapter-agnostic CC channel, `send_file` directive, mock_feishu reaction/file endpoints, tmux-socket env plumbing) so `make e2e` exercises the complete Feishu ↔ CC topology against a running `esrd` + `mock_feishu` with deterministic barrier-based synchronisation.

**Architecture:** Three bash scripts at `tests/e2e/scenarios/` source a shared `common.sh` (env bootstrap, assertion helpers, barrier primitives, trap-based teardown). Production code picks up a `channel_adapter` slot that flows from `agents.yaml` `proxies[].target` → `SessionRouter.do_create` params → `PeerFactory.spawn_peer` ctx → `FeishuChatProxy` thread-state → `PeerServer.build_emit_for_tool` output so the CC chain no longer hardcodes `"feishu"`. A new `_send_file` directive in `adapter.py` consumes the α (base64 in-band) wire shape emitted by the Elixir side; mock_feishu grows `/reactions`, `/files`, `/sent_files` endpoints. A new `ESR_E2E_TMUX_SOCK` env var survives the boot boundary via `Application.get_env(:esr, :tmux_socket_override)` so scripts get isolated tmux state.

**Tech Stack:** Elixir (runtime), Python (adapters, mocks, tests), bash (scenarios), tmux (session pane), aiohttp (mock_feishu), ExUnit + pytest.

**Source spec:** `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/docs/superpowers/specs/2026-04-23-pr7-e2e-feishu-to-cc-design.md` (v1.1, commit `cdd2e77`).

**Branch:** `feature/pr7-e2e` (tip: `cdd2e77`). All commits land on this branch; no rebase.

---

## File Structure

**New files (created by this plan):**

- `docs/notes/pr7-wire-contracts.md` — Task T0, frozen wire sheet.
- `tests/e2e/scenarios/common.sh` — Task A, shared preamble.
- `tests/e2e/scenarios/01_single_user_create_and_end.sh` — Task F.
- `tests/e2e/scenarios/02_two_users_concurrent.sh` — Task G.
- `tests/e2e/scenarios/03_tmux_attach_edit.sh` — Task H.
- `tests/e2e/fixtures/probe_file.txt` — Task A, send_file payload.
- `scripts/tests/test_mock_feishu_reactions.py` — Task B.
- `scripts/tests/test_mock_feishu_send_files.py` — Task B.
- `py/tests/adapter_runners/test_feishu_send_file.py` — Task C.
- `py/tests/adapter_runners/test_feishu_react.py` — Task C.
- `runtime/test/esr/session_router_channel_adapter_test.exs` — Task D1.

**Modified files:**

- `runtime/lib/esr/session_router.ex` — D1: parse `proxies[].target` regex; thread `:channel_adapter` into params; extend `build_ctx/2` for `FeishuAppProxy` to expose the adapter family.
- `runtime/lib/esr/peer_factory.ex` — D1: no code change (pass-through via `ctx` confirmed); docstring nudge if needed.
- `runtime/lib/esr/peers/feishu_chat_proxy.ex` — D1: lift `ctx.channel_adapter` into thread-state map in `init/1`.
- `runtime/lib/esr/peer_server.ex` — D2: add `session_channel_adapter/1` helper; replace 3 `"adapter" => "feishu"` literals; fix `message_id`→`msg_id` bug in `react` emit; rewrite `send_file` emit to α base64 shape.
- `runtime/test/esr/peer_server_test.exs` — D2: new cases for helper + emit shapes.
- `runtime/lib/esr/application.ex` — J1: early reader for `ESR_E2E_TMUX_SOCK`.
- `runtime/lib/esr/peers/tmux_process.ex` — J1: merge `Application.get_env(:esr, :tmux_socket_override)` in `spawn_args/1`.
- `runtime/test/esr/peers/tmux_process_test.exs` — J1: env-override test.
- `runtime/lib/esr_web/cli_channel.ex` — H: support `--field <dotted.path>` argument to `cli:actors/inspect`.
- `runtime/test/esr/peer_server_test.exs` or new file under `runtime/test/esr_web/` — H: test the new field extraction.
- `adapters/feishu/src/esr_feishu/adapter.py` — C: add `_send_file` + `_send_file_mock` + `_send_file_live`; add mock branch to `_react`; extend `on_directive` dispatch.
- `scripts/mock_feishu.py` — B: `/reactions` (POST + GET), `/files` (POST), `/sent_files` (GET), state slots, on-disk persistence.
- `adapters/cc_mcp/src/esr_cc_mcp/tools.py` — K1: sanitize 6 Feishu mentions.
- `runtime/lib/esr/peers/cc_proxy.ex` — K2: drop `FeishuChatProxy` literal from moduledoc.
- `runtime/lib/esr/peers/cc_process.ex` — K2: drop `FeishuChatProxy` literal from moduledoc.
- `adapters/cc_mcp/tests/test_tools_schema_language.py` — K1: new pytest asserting no `feishu` substring case-insensitive.
- `Makefile` — Task I: add `e2e`, `e2e-01`, `e2e-02`, `e2e-03`, `e2e-ci` targets inline.
- `tests/e2e/README.md` — Task J: docs cross-ref.

---

## Task Quick-Reference

| # | Task | Depends on | Files touched |
|---|------|------------|---------------|
| T0 | Wire contracts doc | — | `docs/notes/pr7-wire-contracts.md` |
| A | `common.sh` + fixture | T0 | `tests/e2e/scenarios/common.sh`, `tests/e2e/fixtures/probe_file.txt` |
| B | mock_feishu endpoints | T0 | `scripts/mock_feishu.py`, `scripts/tests/test_mock_feishu_*.py` |
| C | adapter.py extensions | T0 | `adapters/feishu/src/esr_feishu/adapter.py`, `py/tests/adapter_runners/test_feishu_*.py` |
| D1 | `channel_adapter` plumbing | T0 | `session_router.ex`, `feishu_chat_proxy.ex`, new router test |
| D2 | peer_server emit + msg_id fix | D1 | `peer_server.ex`, `peer_server_test.exs` |
| J1 | tmux_socket env plumbing | — | `application.ex`, `tmux_process.ex`, `tmux_process_test.exs` |
| F | scenario 01 | A, B, C, D2, J1 | `tests/e2e/scenarios/01_*.sh` |
| G | scenario 02 | A, B, C, D2, J1 | `tests/e2e/scenarios/02_*.sh` |
| H | scenario 03 + CLI field extract | A, D2, J1 | `tests/e2e/scenarios/03_*.sh`, `cli_channel.ex` |
| K1 | tools.py sanitization | — | `adapters/cc_mcp/src/esr_cc_mcp/tools.py`, new schema-language test |
| K2 | peer docstring sanitization | — | `cc_proxy.ex`, `cc_process.ex` |
| I | Makefile + CI mode | F, G, H | `Makefile` |
| J | Docs cross-ref | I | `tests/e2e/README.md` |

Total: **14 tasks** (as pinned in spec §15.1).

---

## Task T0: Wire-contract sheet

**Goal:** One ~100-line doc pinning the exact payload shapes that Tasks B, C, D1, D2 will implement against. Prevents drift between the three Python / Elixir sides.

**Files:**
- Create: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/docs/notes/pr7-wire-contracts.md`

- [ ] **Step 1: Create the contract doc with every wire shape inlined**

Write the file with this exact content:

````markdown
# PR-7 wire contracts (frozen)

Pinned by plan T0 on 2026-04-23; all of B, C, D1, D2 consume these
shapes as-is. Any change to this file requires re-ordering the
downstream tasks.

## 1. `channel_adapter` parsing

Source: `agents.yaml` `proxies[].target`, e.g.:

```yaml
proxies:
  - name: feishu_app_proxy
    impl: Esr.Peers.FeishuAppProxy
    target: "admin::feishu_app_adapter_${app_id}"
```

**Parsing decision (frozen):** the regex captures the entire token up
to `_adapter_` (i.e. `feishu_app`), not just `feishu`. Rationale: the
review surfaced this greediness explicitly; we accept `feishu_app` as
the adapter family rather than add anchoring that diverges from how
the admin-peer-name already combines app+adapter. Downstream consumers
(Python adapter; emit payload) treat the family as an opaque token.

```
target := "admin::<adapter_family>_adapter_<app_id>"
regex  := ~r/^admin::([a-z_]+)_adapter_.*$/
```

- Match on `"admin::feishu_app_adapter_default"` → capture group 1
  equals `"feishu_app"`.
- Non-matching targets fall back to `"feishu"` with a
  `Logger.warning`.

**Test cases (D1 must cover all four):**

| Input target | Expected `channel_adapter` | Log? |
|--------------|----------------------------|------|
| `"admin::feishu_app_adapter_default"` | `"feishu_app"` | no |
| `"admin::feishu_app_adapter_e2e-mock"` | `"feishu_app"` | no |
| `"admin::slack_v2_adapter_acme"` | `"slack_v2"` | no |
| `"admin::malformed-no-underscore"` | `"feishu"` (fallback) | warning |

## 2. `react` directive emit shape (D2, correcting §5.1 bug)

**Input** (what CC's MCP tool passes — UNCHANGED):

```json
{"message_id": "om_xxx", "emoji_type": "THUMBSUP"}
```

**Emit** (Elixir → adapter — CHANGED: `message_id`→`msg_id`):

```elixir
%{
  "type" => "emit",
  "adapter" => session_channel_adapter(state),
  "action" => "react",
  "args" => %{"msg_id" => mid, "emoji_type" => emoji}
}
```

Adapter reads `args["msg_id"]` (matches `_pin`, `_unpin`, `_download_file`
convention).

## 3. `send_file` directive emit shape (D2, §6.2 α shape)

**Input** (MCP tool — UNCHANGED):

```json
{"chat_id": "oc_xxx", "file_path": "/abs/path"}
```

**Emit** (Elixir → adapter — base64 in-band):

```elixir
%{
  "type" => "emit",
  "adapter" => session_channel_adapter(state),
  "action" => "send_file",
  "args" => %{
    "chat_id" => cid,
    "file_name" => Path.basename(fp),
    "content_b64" => Base.encode64(bytes),
    "sha256" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  }
}
```

Error shape: `{:error, "send_file cannot read <path>: <reason>"}` on
read failure.

## 4. Mock Feishu endpoints (B)

### 4a. `POST /open-apis/im/v1/messages/:message_id/reactions`

Body: `{"reaction_type": {"emoji_type": "THUMBSUP"}}`
Response: `{"code": 0, "msg": "", "data": {"reaction_id": "rc_mock_<hex>", "message_id": "<id>"}}`
Side effect: append `{message_id, emoji_type, ts_unix_ms}` to
`self._reactions`.

### 4b. `GET /reactions`

Response: `[{"message_id": "...", "emoji_type": "...", "ts_unix_ms": ...}, ...]`
(newest-last).

### 4c. `POST /open-apis/im/v1/files`

Multipart/form-data OR JSON body with:
- `file_type`: `"stream"`
- `file_name`: string
- `file` (multipart) OR `content_b64` (JSON): bytes

Response: `{"code": 0, "msg": "", "data": {"file_key": "file_mock_<hex>"}}`
Side effect: persist bytes to `/tmp/mock-feishu-files-<port>/<file_key>`;
append `{chat_id: "", file_key, file_name, size, sha256, ts_unix_ms}`
to `self._uploaded_files` (chat_id is set to `""` at upload time —
filled in on the follow-up send-message call).

### 4d. `POST /open-apis/im/v1/messages?receive_id_type=chat_id` (msg_type=file extension)

Body: `{"receive_id": "oc_xxx", "msg_type": "file", "content": "{\"file_key\": \"...\"}"}`
Side effect: look up the file_key in `self._uploaded_files`, back-fill
`chat_id = receive_id`. Response identical to existing text-message path.

### 4e. `GET /sent_files`

Response: `[{"chat_id": "...", "file_key": "...", "file_name": "...", "size": N, "sha256": "...", "ts_unix_ms": ...}, ...]`
Only entries whose chat_id is non-empty (i.e. already linked to a
send-message call).

## 5. `ESR_E2E_TMUX_SOCK` env → Application env (J1)

Boot-time reader in `application.ex` (early in `start/2`, before the
`children` list is built so the env is set before any peer
spawn):

```elixir
case System.get_env("ESR_E2E_TMUX_SOCK") do
  nil -> :ok
  ""  -> :ok
  path ->
    Application.put_env(:esr, :tmux_socket_override, path)
end
```

Consumer in `tmux_process.ex::spawn_args/1`:

```elixir
case Esr.Peer.get_param(params, :tmux_socket) ||
       Application.get_env(:esr, :tmux_socket_override) do
  nil  -> base
  path -> Map.put(base, :tmux_socket, path)
end
```

Observable invariant (J1 test target): after
`Application.put_env(:esr, :tmux_socket_override, "/tmp/foo.sock")`,
`TmuxProcess.spawn_args(%{})` returns a map containing
`tmux_socket: "/tmp/foo.sock"`.

## 6. `cli:actors/inspect --field` (H)

Extension to `EsrWeb.CliChannel.dispatch/2`. Accepts a payload with
`{"arg" => actor_id, "field" => "state.session_name"}`. Response shape:

```json
{"data": {"actor_id": "...", "field": "state.session_name", "value": "esr_cc_42"}}
```

Resolution: `get_in(describe_map, String.split(field, "."))`. Missing
key → `{"data": {"error": "field not present", "field": "<f>"}}`.
````

- [ ] **Step 2: Commit**

```bash
git add docs/notes/pr7-wire-contracts.md
git commit -m "$(cat <<'EOF'
docs(notes): PR-7 frozen wire contracts (T0)

Pins channel_adapter regex, react/send_file emit shapes, mock_feishu
endpoints, tmux_socket env plumbing, and cli:actors/inspect --field —
all downstream PR-7 tasks consume these shapes as-is.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task A: `common.sh` + e2e fixture

**Goal:** Shared preamble (env, assertion helpers, barrier primitives, trap teardown) all three scripts source. Plus a 1 KB probe file that scenario 01 sends through `send_file`.

**Files:**
- Create: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/tests/e2e/fixtures/probe_file.txt`
- Create: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/tests/e2e/scenarios/common.sh`

- [ ] **Step 1: Create the fixture directory + probe file**

```bash
mkdir -p /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/tests/e2e/fixtures
printf 'PR-7 probe file\nLine 2\nLine 3\n' \
  > /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/tests/e2e/fixtures/probe_file.txt
```

Verify: file exists, `wc -c` reports < 2048 bytes.

- [ ] **Step 2: Write a failing self-test `common_test.sh` that exercises every helper**

Create `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/tests/e2e/scenarios/_common_selftest.sh`:

```bash
#!/usr/bin/env bash
# Self-test for common.sh — exits non-zero on any helper misbehaviour.
# Run in CI before the real scenarios to catch common.sh regressions.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

# assert_eq positive
assert_eq "hello" "hello" "equal strings should pass"

# assert_eq negative — run in subshell, expect non-zero
( assert_eq "a" "b" "deliberate mismatch" ) && \
  { echo "FAIL: assert_eq accepted mismatch"; exit 1; } || true

# assert_contains
assert_contains "hello world" "world" "contains substring"

# barrier round-trip
barrier_signal test_barrier_self
barrier_wait test_barrier_self 5

# baseline diff idempotency
snap_a=$(e2e_tmp_baseline_snapshot)
snap_b=$(e2e_tmp_baseline_snapshot)
[[ "$snap_a" == "$snap_b" ]] || { echo "FAIL: baseline not idempotent"; exit 1; }

echo "PASS: common.sh self-test"
```

- [ ] **Step 3: Run the self-test — expect fail (common.sh does not exist yet)**

```bash
bash /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/tests/e2e/scenarios/_common_selftest.sh
```

Expected: non-zero exit with `common.sh: No such file or directory` (or similar "source failed" error).

- [ ] **Step 4: Write `common.sh` that makes the self-test pass**

Create `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/tests/e2e/scenarios/common.sh`:

```bash
#!/usr/bin/env bash
# Shared preamble for PR-7 e2e scenarios. Sourced by 01/02/03.
# See docs/superpowers/specs/2026-04-23-pr7-e2e-feishu-to-cc-design.md §3.1.

set -Eeuo pipefail

# --- env bootstrap ---------------------------------------------------
: "${ESR_E2E_RUN_ID:=pr7-$(date +%s)-$$}"
: "${ESRD_INSTANCE:=e2e-${ESR_E2E_RUN_ID}}"
: "${ESRD_HOME:=/tmp/esrd-${ESR_E2E_RUN_ID}}"
: "${MOCK_FEISHU_PORT:=8201}"
: "${ESR_E2E_BARRIER_DIR:=/tmp/esr-e2e-${ESR_E2E_RUN_ID}/barriers}"
: "${ESR_E2E_UPLOADS_DIR:=${ESRD_HOME}/default/uploads}"
: "${ESR_E2E_TMUX_SOCK:=/tmp/esr-e2e-${ESR_E2E_RUN_ID}/tmux.sock}"

export ESR_E2E_RUN_ID ESRD_INSTANCE ESRD_HOME MOCK_FEISHU_PORT
export ESR_E2E_BARRIER_DIR ESR_E2E_UPLOADS_DIR ESR_E2E_TMUX_SOCK

mkdir -p "${ESR_E2E_BARRIER_DIR}" "${ESRD_HOME}" "$(dirname "${ESR_E2E_TMUX_SOCK}")"

# --- repo root (for paths inside helpers) ----------------------------
_E2E_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export _E2E_REPO_ROOT

# --- traps ------------------------------------------------------------
trap '_on_err $? $LINENO' ERR
trap '_on_exit' EXIT

_on_err() {
  local exit_code=$1 line=$2
  echo "FAIL: line ${line} exit ${exit_code} run_id=${ESR_E2E_RUN_ID}" >&2
  if [[ -f "/tmp/mock-feishu-${ESR_E2E_RUN_ID}.log" ]]; then
    echo "--- mock_feishu.log tail ---" >&2
    tail -n 40 "/tmp/mock-feishu-${ESR_E2E_RUN_ID}.log" >&2 || true
  fi
}

_on_exit() {
  # Idempotent teardown — safe to run twice.
  _e2e_teardown || true
}

_e2e_teardown() {
  # (full body in Task I; stub here — expanded when Makefile wiring lands)
  [[ -f "/tmp/mock-feishu-${ESR_E2E_RUN_ID}.pid" ]] && {
    kill -9 "$(cat /tmp/mock-feishu-${ESR_E2E_RUN_ID}.pid)" 2>/dev/null || true
    rm -f "/tmp/mock-feishu-${ESR_E2E_RUN_ID}.pid"
  }
  rm -f /tmp/.sidecar.pid 2>/dev/null || true
  rm -f /tmp/esr-worker-*.pid 2>/dev/null || true
  if [[ -S "${ESR_E2E_TMUX_SOCK}" ]]; then
    tmux -S "${ESR_E2E_TMUX_SOCK}" kill-server 2>/dev/null || true
  fi
  rm -rf "${ESRD_HOME}" "${ESR_E2E_BARRIER_DIR}" \
         "/tmp/mock-feishu-files-${MOCK_FEISHU_PORT}" 2>/dev/null || true
}

# --- assertion helpers -----------------------------------------------
_fail_with_context() {
  echo "FAIL: $* run_id=${ESR_E2E_RUN_ID} line=${BASH_LINENO[0]}" >&2
  return 1
}

assert_eq() {
  local actual=$1 expected=$2 ctx=${3:-"assert_eq"}
  if [[ "$actual" != "$expected" ]]; then
    _fail_with_context "${ctx}: expected '${expected}' got '${actual}'"
    return 1
  fi
}

assert_contains() {
  local haystack=$1 needle=$2 ctx=${3:-"assert_contains"}
  if [[ "$haystack" != *"$needle"* ]]; then
    _fail_with_context "${ctx}: '${needle}' not in '${haystack}'"
    return 1
  fi
}

assert_not_contains() {
  local haystack=$1 needle=$2 ctx=${3:-"assert_not_contains"}
  if [[ "$haystack" == *"$needle"* ]]; then
    _fail_with_context "${ctx}: unexpected '${needle}' in '${haystack}'"
    return 1
  fi
}

assert_ok() {
  local ctx=${E2E_ASSERT_CTX:-"assert_ok"}
  "$@" || _fail_with_context "${ctx}: command failed: $*"
}

assert_file_exists() {
  [[ -e "$1" ]] || _fail_with_context "assert_file_exists: missing $1"
}

assert_file_absent() {
  [[ ! -e "$1" ]] || _fail_with_context "assert_file_absent: unexpected $1"
}

# --- barrier primitives ----------------------------------------------
barrier_signal() {
  local name=$1
  touch "${ESR_E2E_BARRIER_DIR}/${name}"
}

barrier_wait() {
  local name=$1 timeout_s=${2:-30} elapsed=0
  while [[ ! -e "${ESR_E2E_BARRIER_DIR}/${name}" ]]; do
    sleep 0.2
    elapsed=$(awk "BEGIN {print $elapsed + 0.2}")
    if awk "BEGIN {exit !($elapsed > $timeout_s)}"; then
      _fail_with_context "barrier_wait: '${name}' timeout after ${timeout_s}s"
      return 1
    fi
  done
}

# --- mock-feishu assertion helpers -----------------------------------
assert_actors_list_has() {
  local substr=$1 ctx=${2:-"assert_actors_list_has"}
  local out
  out=$(uv run --project "${_E2E_REPO_ROOT}/py" esr actors list 2>&1 || true)
  assert_contains "$out" "$substr" "${ctx} [actors list]"
}

assert_actors_list_lacks() {
  local substr=$1 ctx=${2:-"assert_actors_list_lacks"}
  local out
  out=$(uv run --project "${_E2E_REPO_ROOT}/py" esr actors list 2>&1 || true)
  assert_not_contains "$out" "$substr" "${ctx} [actors list]"
}

assert_mock_feishu_sent_includes() {
  local chat_id=$1 text_substr=$2
  curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/sent_messages" \
    | jq -e --arg cid "$chat_id" --arg txt "$text_substr" \
      '.[] | select(.receive_id==$cid) | .content | contains($txt)' >/dev/null \
    || _fail_with_context "expected mock_feishu.sent_messages for $chat_id to include '$text_substr'"
}

assert_mock_feishu_reactions_count() {
  local message_id=$1 expected=$2
  local count
  count=$(curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/reactions" \
    | jq --arg mid "$message_id" '[.[] | select(.message_id==$mid)] | length')
  assert_eq "$count" "$expected" "reactions for ${message_id}"
}

assert_mock_feishu_file_sha() {
  local chat_id=$1 expected_sha=$2
  local actual
  actual=$(curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/sent_files" \
    | jq -r --arg cid "$chat_id" '.[] | select(.chat_id==$cid) | .sha256' \
    | head -n1)
  assert_eq "$actual" "$expected_sha" "sha256 of file sent to ${chat_id}"
}

assert_tmux_pane_contains() {
  local session=$1 substr=$2
  local pane_txt
  pane_txt=$(tmux -S "${ESR_E2E_TMUX_SOCK}" capture-pane -p -t "${session}" 2>&1)
  assert_contains "$pane_txt" "$substr" "tmux pane ${session}"
}

# --- baseline snapshot (knob c) --------------------------------------
e2e_tmp_baseline_snapshot() {
  # Deterministic hash of /tmp entries that could confuse cleanup
  # assertions — excludes the run's own paths.
  ls -1 /tmp 2>/dev/null \
    | grep -Ev "^(esrd-${ESR_E2E_RUN_ID}|esr-e2e-${ESR_E2E_RUN_ID}|mock-feishu-files-${MOCK_FEISHU_PORT}|mock-feishu-${ESR_E2E_RUN_ID}\\..*|\\.sidecar\\.pid|esr-worker-.*\\.pid)$" \
    | sort \
    | shasum -a 256 \
    | awk '{print $1}'
}

assert_baseline_clean() {
  local before=$1
  local after
  after=$(e2e_tmp_baseline_snapshot)
  assert_eq "$after" "$before" "/tmp baseline unchanged"
}

# --- one-shot setup helpers (bodies filled in by Tasks F/G/H/I) ------
start_mock_feishu() {
  local log="/tmp/mock-feishu-${ESR_E2E_RUN_ID}.log"
  local pidf="/tmp/mock-feishu-${ESR_E2E_RUN_ID}.pid"
  ( cd "${_E2E_REPO_ROOT}" && \
    uv run --project py python scripts/mock_feishu.py \
      --port "${MOCK_FEISHU_PORT}" > "$log" 2>&1 &
    echo $! > "$pidf" )
  # Readiness probe
  for _ in $(seq 1 50); do
    if curl -sSf "http://127.0.0.1:${MOCK_FEISHU_PORT}/sent_messages" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  _fail_with_context "mock_feishu did not come up on port ${MOCK_FEISHU_PORT}"
}

load_agent_yaml() {
  mkdir -p "${ESRD_HOME}/default"
  cp "${_E2E_REPO_ROOT}/runtime/test/esr/fixtures/agents/simple.yaml" \
     "${ESRD_HOME}/default/agents.yaml"
}

start_esrd() {
  # Leaves ESR_E2E_TMUX_SOCK exported so application.ex's boot reader
  # picks it up (J1).
  ( cd "${_E2E_REPO_ROOT}" && \
    ESRD_HOME="${ESRD_HOME}" ESRD_INSTANCE="${ESRD_INSTANCE}" \
    ESR_E2E_TMUX_SOCK="${ESR_E2E_TMUX_SOCK}" \
    bash scripts/esrd.sh start --instance="${ESRD_INSTANCE}" )
}

register_feishu_adapter() {
  # Drop the adapter record so `/new-session` can resolve the proxy target.
  mkdir -p "${ESRD_HOME}/default/admin_queue/in"
  cat > "${ESRD_HOME}/default/admin_queue/in/register_adapter_feishu.json" <<JSON
{
  "command": "register_adapter",
  "args": {
    "adapter_family": "feishu_app",
    "app_id": "e2e-mock",
    "base_url": "http://127.0.0.1:${MOCK_FEISHU_PORT}"
  }
}
JSON
}
```

- [ ] **Step 5: Run the self-test — expect pass**

```bash
bash /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/tests/e2e/scenarios/_common_selftest.sh
```

Expected: `PASS: common.sh self-test` and exit 0.

- [ ] **Step 6: Commit**

```bash
git add tests/e2e/fixtures/probe_file.txt \
        tests/e2e/scenarios/common.sh \
        tests/e2e/scenarios/_common_selftest.sh
git commit -m "$(cat <<'EOF'
feat(e2e): common.sh preamble + probe_file fixture (Task A)

Assertion helpers, barrier primitives, trap-based teardown, and one-shot
setup helpers (start_mock_feishu, load_agent_yaml, start_esrd,
register_feishu_adapter). Covers spec §3.1 + §8 assertion catalogue.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task B: mock_feishu endpoints (`/reactions`, `/files`, `/sent_files`)

**Goal:** Extend `MockFeishu` to persist reactions + uploaded files so scenarios can assert on them. Contract frozen in T0 §4.

**Files:**
- Modify: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/scripts/mock_feishu.py`
- Create: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/scripts/tests/test_mock_feishu_reactions.py`
- Create: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/scripts/tests/test_mock_feishu_send_files.py`

- [ ] **Step 1: Write failing test for `/reactions`**

Create `scripts/tests/test_mock_feishu_reactions.py`:

```python
"""Tests for mock_feishu's /reactions endpoints (T0 §4a, §4b)."""
import json
from urllib.request import Request, urlopen

import pytest

from scripts.mock_feishu import MockFeishu


@pytest.mark.asyncio
async def test_post_reaction_appends_and_get_lists() -> None:
    mock = MockFeishu()
    base = await mock.start(port=0)
    try:
        # POST a reaction
        body = json.dumps({"reaction_type": {"emoji_type": "THUMBSUP"}}).encode()
        req = Request(
            f"{base}/open-apis/im/v1/messages/om_test_1/reactions",
            data=body,
            headers={"content-type": "application/json"},
            method="POST",
        )
        with urlopen(req, timeout=5) as resp:
            payload = json.loads(resp.read())
        assert payload["code"] == 0
        assert payload["data"]["message_id"] == "om_test_1"
        assert payload["data"]["reaction_id"].startswith("rc_mock_")

        # GET /reactions
        with urlopen(f"{base}/reactions", timeout=5) as resp:
            listing = json.loads(resp.read())
        assert len(listing) == 1
        assert listing[0]["message_id"] == "om_test_1"
        assert listing[0]["emoji_type"] == "THUMBSUP"
        assert "ts_unix_ms" in listing[0]
    finally:
        await mock.stop()
```

- [ ] **Step 2: Run — expect fail (endpoint missing)**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor && \
  uv run --project py pytest scripts/tests/test_mock_feishu_reactions.py -v
```

Expected: FAIL with 404 on POST or similar routing error.

- [ ] **Step 3: Add `/reactions` endpoints to `mock_feishu.py`**

In `MockFeishu.__init__`, add:

```python
self._reactions: list[dict[str, Any]] = []
```

In `MockFeishu.start`, register:

```python
app.router.add_post(
    "/open-apis/im/v1/messages/{message_id}/reactions",
    self._on_create_reaction,
)
app.router.add_get("/reactions", self._on_get_reactions)
```

Add handlers (place near `_on_get_sent_messages`):

```python
async def _on_create_reaction(self, request: web.Request) -> web.Response:
    message_id = request.match_info["message_id"]
    body = await request.json()
    emoji_type = body.get("reaction_type", {}).get("emoji_type", "")
    reaction_id = "rc_mock_" + secrets.token_hex(8)
    self._reactions.append({
        "message_id": message_id,
        "emoji_type": emoji_type,
        "ts_unix_ms": int(time.time() * 1000),
    })
    return web.json_response({
        "code": 0,
        "msg": "",
        "data": {"reaction_id": reaction_id, "message_id": message_id},
    })

async def _on_get_reactions(self, _request: web.Request) -> web.Response:
    return web.json_response(self._reactions)
```

- [ ] **Step 4: Run — expect pass**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor && \
  uv run --project py pytest scripts/tests/test_mock_feishu_reactions.py -v
```

Expected: PASS.

- [ ] **Step 5: Write failing test for `/files` + `/sent_files`**

Create `scripts/tests/test_mock_feishu_send_files.py`:

```python
"""Tests for mock_feishu's /files + /sent_files endpoints (T0 §4c-e)."""
import base64
import hashlib
import json
from urllib.request import Request, urlopen

import pytest

from scripts.mock_feishu import MockFeishu


@pytest.mark.asyncio
async def test_upload_then_send_file_links_chat_id() -> None:
    mock = MockFeishu()
    base = await mock.start(port=0)
    try:
        payload_bytes = b"PR-7 probe bytes\n"
        b64 = base64.b64encode(payload_bytes).decode()

        # Step 1: upload (JSON form — plan uses JSON+content_b64 path)
        req = Request(
            f"{base}/open-apis/im/v1/files",
            data=json.dumps({
                "file_type": "stream",
                "file_name": "probe.txt",
                "content_b64": b64,
            }).encode(),
            headers={"content-type": "application/json"},
            method="POST",
        )
        with urlopen(req, timeout=5) as resp:
            upload = json.loads(resp.read())
        file_key = upload["data"]["file_key"]
        assert file_key.startswith("file_mock_")

        # Pre-link state: /sent_files is empty (chat_id=="")
        with urlopen(f"{base}/sent_files", timeout=5) as resp:
            pre = json.loads(resp.read())
        assert pre == []

        # Step 2: send-as-file-message
        send_req = Request(
            f"{base}/open-apis/im/v1/messages?receive_id_type=chat_id",
            data=json.dumps({
                "receive_id": "oc_mock_A",
                "msg_type": "file",
                "content": json.dumps({"file_key": file_key}),
            }).encode(),
            headers={"content-type": "application/json"},
            method="POST",
        )
        with urlopen(send_req, timeout=5) as resp:
            send_resp = json.loads(resp.read())
        assert send_resp["code"] == 0

        # /sent_files now has one linked entry
        with urlopen(f"{base}/sent_files", timeout=5) as resp:
            post = json.loads(resp.read())
        assert len(post) == 1
        assert post[0]["chat_id"] == "oc_mock_A"
        assert post[0]["file_key"] == file_key
        assert post[0]["file_name"] == "probe.txt"
        assert post[0]["size"] == len(payload_bytes)
        assert post[0]["sha256"] == hashlib.sha256(payload_bytes).hexdigest()
    finally:
        await mock.stop()
```

- [ ] **Step 6: Run — expect fail**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor && \
  uv run --project py pytest scripts/tests/test_mock_feishu_send_files.py -v
```

Expected: FAIL (404 on `/open-apis/im/v1/files`).

- [ ] **Step 7: Add `/files` + `/sent_files` + extend existing send-message for `msg_type=file`**

In `MockFeishu.__init__`, add:

```python
self._uploaded_files: list[dict[str, Any]] = []
self._files_dir: Path | None = None  # set in start()
```

Import `hashlib` and `pathlib.Path` at top of file.

In `MockFeishu.start`, before `await self._runner.setup()`:

```python
self._files_dir = Path(f"/tmp/mock-feishu-files-{port or 'rand'}")
self._files_dir.mkdir(parents=True, exist_ok=True)
```

And register routes:

```python
app.router.add_post("/open-apis/im/v1/files", self._on_upload_file)
app.router.add_get("/sent_files", self._on_get_sent_files)
```

After `self._port` is known, rename the files dir if it was `rand`:

```python
if self._files_dir.name.endswith("rand"):
    new_dir = Path(f"/tmp/mock-feishu-files-{self._port}")
    self._files_dir.rename(new_dir)
    self._files_dir = new_dir
```

Add handler:

```python
async def _on_upload_file(self, request: web.Request) -> web.Response:
    ctype = request.headers.get("content-type", "")
    if "application/json" in ctype:
        body = await request.json()
        file_name = body["file_name"]
        data = base64.b64decode(body["content_b64"])
    else:
        form = await request.post()
        file_name = form["file_name"]
        file_field = form["file"]
        data = file_field.file.read() if hasattr(file_field, "file") else bytes(file_field)

    file_key = "file_mock_" + secrets.token_hex(8)
    assert self._files_dir is not None
    (self._files_dir / file_key).write_bytes(data)
    self._uploaded_files.append({
        "chat_id": "",  # filled on the send-message call
        "file_key": file_key,
        "file_name": file_name,
        "size": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "ts_unix_ms": int(time.time() * 1000),
    })
    return web.json_response({
        "code": 0, "msg": "", "data": {"file_key": file_key},
    })

async def _on_get_sent_files(self, _request: web.Request) -> web.Response:
    linked = [f for f in self._uploaded_files if f["chat_id"]]
    return web.json_response(linked)
```

Add `import base64` at top.

Extend `_on_create_message` (around line where it reads `msg_type`) to back-fill on `msg_type=file`:

```python
if body.get("msg_type") == "file":
    content = json.loads(body.get("content") or "{}")
    file_key = content.get("file_key", "")
    for entry in self._uploaded_files:
        if entry["file_key"] == file_key and not entry["chat_id"]:
            entry["chat_id"] = body.get("receive_id", "")
            break
```

- [ ] **Step 8: Run both mock tests — expect pass**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor && \
  uv run --project py pytest scripts/tests/test_mock_feishu_reactions.py \
                              scripts/tests/test_mock_feishu_send_files.py -v
```

Expected: PASS (2 tests).

- [ ] **Step 9: Run the existing mock_feishu test to confirm no regression**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor && \
  uv run --project py pytest scripts/tests/test_mock_feishu.py scripts/tests/test_mock_feishu_conformance.py -v
```

Expected: PASS (all pre-existing).

- [ ] **Step 10: Commit**

```bash
git add scripts/mock_feishu.py scripts/tests/test_mock_feishu_reactions.py \
        scripts/tests/test_mock_feishu_send_files.py
git commit -m "$(cat <<'EOF'
feat(mock_feishu): reactions + file upload endpoints (Task B)

Adds POST /open-apis/im/v1/messages/:id/reactions, GET /reactions,
POST /open-apis/im/v1/files, GET /sent_files, and msg_type=file
back-fill on the existing send-message endpoint. Pinned to T0 §4.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task C: `adapter.py` extensions (`_send_file`, `_react` mock branch)

**Goal:** The Python adapter consumes the α base64 shape for `send_file` and gains a mock-mode branch for `_react` so scenario 01 can exercise the reactions path without live lark_oapi.

**Files:**
- Modify: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/adapters/feishu/src/esr_feishu/adapter.py`
- Create: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/py/tests/adapter_runners/test_feishu_send_file.py`
- Create: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/py/tests/adapter_runners/test_feishu_react.py`

- [ ] **Step 1: Write failing test for `_send_file` happy path + sha mismatch**

Create `py/tests/adapter_runners/test_feishu_send_file.py`:

```python
"""Test α-shape send_file directive dispatch (spec §6, T0 §3)."""
import base64
import hashlib
import json
from types import SimpleNamespace
from urllib.request import Request, urlopen

import pytest

from scripts.mock_feishu import MockFeishu
from esr_feishu.adapter import FeishuAdapter


@pytest.mark.asyncio
async def test_send_file_mock_round_trip() -> None:
    mock = MockFeishu()
    base_url = await mock.start(port=0)
    try:
        cfg = SimpleNamespace(
            app_id="e2e-mock", app_secret="s", base_url=base_url,
            uploads_dir="/tmp",
        )
        adapter = FeishuAdapter(cfg)

        payload = b"hello PR-7"
        sha = hashlib.sha256(payload).hexdigest()
        args = {
            "chat_id": "oc_mock_A",
            "file_name": "probe.txt",
            "content_b64": base64.b64encode(payload).decode(),
            "sha256": sha,
        }
        result = await adapter.on_directive("send_file", args)
        assert result["ok"] is True, result

        # Assert mock received file and linked it
        with urlopen(f"{base_url}/sent_files", timeout=5) as resp:
            listing = json.loads(resp.read())
        assert len(listing) == 1
        assert listing[0]["chat_id"] == "oc_mock_A"
        assert listing[0]["sha256"] == sha
    finally:
        await mock.stop()


@pytest.mark.asyncio
async def test_send_file_sha_mismatch_rejected() -> None:
    mock = MockFeishu()
    base_url = await mock.start(port=0)
    try:
        cfg = SimpleNamespace(
            app_id="e2e-mock", app_secret="s", base_url=base_url,
            uploads_dir="/tmp",
        )
        adapter = FeishuAdapter(cfg)

        args = {
            "chat_id": "oc_mock_A",
            "file_name": "probe.txt",
            "content_b64": base64.b64encode(b"actual").decode(),
            "sha256": "0" * 64,  # wrong
        }
        result = await adapter.on_directive("send_file", args)
        assert result["ok"] is False
        assert "sha256 mismatch" in result["error"]
    finally:
        await mock.stop()
```

- [ ] **Step 2: Run — expect fail (no `send_file` action)**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor && \
  uv run --project py pytest py/tests/adapter_runners/test_feishu_send_file.py -v
```

Expected: FAIL — `on_directive` returns `{"ok": False, "error": "unknown action: send_file"}`.

- [ ] **Step 3: Implement `_send_file` + mock branch**

In `adapter.py`, extend `on_directive` (near line 343):

```python
if action == "send_file":
    return await self._with_ratelimit_retry(lambda: self._send_file(args))
```

Add methods (place after `_download_file`, near line 550):

```python
def _send_file(self, args: dict[str, Any]) -> dict[str, Any]:
    """α wire shape (spec §6.1): base64 in-band + sha256 check."""
    import base64 as _b64
    import hashlib

    chat_id = args["chat_id"]
    file_name = args["file_name"]
    content_b64 = args["content_b64"]
    expected_sha = args["sha256"]

    try:
        bytes_ = _b64.b64decode(content_b64, validate=True)
    except Exception as exc:  # noqa: BLE001 — surface any b64 error
        return {"ok": False, "error": f"b64 decode failed: {exc}"}

    actual_sha = hashlib.sha256(bytes_).hexdigest()
    if actual_sha != expected_sha:
        return {"ok": False, "error": "sha256 mismatch"}

    base_url = getattr(self._config, "base_url", "") or ""
    if base_url.startswith(("http://127.0.0.1", "http://localhost")):
        return self._send_file_mock(base_url, chat_id, file_name, bytes_)

    return self._send_file_live(chat_id, file_name, bytes_)


def _send_file_mock(
    self, base_url: str, chat_id: str, file_name: str, bytes_: bytes
) -> dict[str, Any]:
    import base64 as _b64
    import urllib.error
    import urllib.request

    upload_body = json.dumps({
        "file_type": "stream",
        "file_name": file_name,
        "content_b64": _b64.b64encode(bytes_).decode(),
    }).encode("utf-8")
    upload_req = urllib.request.Request(
        f"{base_url}/open-apis/im/v1/files",
        data=upload_body,
        headers={"content-type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(upload_req, timeout=5) as resp:
            upload = json.loads(resp.read())
    except urllib.error.URLError as exc:
        return {"ok": False, "error": f"mock upload failed: {exc}"}

    file_key = upload.get("data", {}).get("file_key")
    if not file_key:
        return {"ok": False, "error": "mock upload did not return file_key"}

    msg_body = json.dumps({
        "receive_id": chat_id,
        "msg_type": "file",
        "content": json.dumps({"file_key": file_key}),
    }).encode("utf-8")
    msg_req = urllib.request.Request(
        f"{base_url}/open-apis/im/v1/messages?receive_id_type=chat_id",
        data=msg_body,
        headers={"content-type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(msg_req, timeout=5) as resp:
            data = json.loads(resp.read())
    except urllib.error.URLError as exc:
        return {"ok": False, "error": f"mock send-file-message failed: {exc}"}
    return {"ok": True, "result": data.get("data") or {"file_key": file_key}}


def _send_file_live(
    self, chat_id: str, file_name: str, bytes_: bytes
) -> dict[str, Any]:
    """Live path parity with _send_message. Untested in PR-7 (mock-only)."""
    import lark_oapi.api.im.v1 as im_v1  # noqa: F401 — import guard
    # Deferred: two-step upload + message create against real Lark.
    return {"ok": False, "error": "live send_file not yet implemented"}
```

- [ ] **Step 4: Run send_file tests — expect pass**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor && \
  uv run --project py pytest py/tests/adapter_runners/test_feishu_send_file.py -v
```

Expected: PASS (2 tests).

- [ ] **Step 5: Write failing test for `_react` mock branch**

Create `py/tests/adapter_runners/test_feishu_react.py`:

```python
"""Test react directive with corrected msg_id key (spec §5.1)."""
import json
from types import SimpleNamespace
from urllib.request import urlopen

import pytest

from scripts.mock_feishu import MockFeishu
from esr_feishu.adapter import FeishuAdapter


@pytest.mark.asyncio
async def test_react_mock_emits_reaction() -> None:
    mock = MockFeishu()
    base_url = await mock.start(port=0)
    try:
        cfg = SimpleNamespace(
            app_id="e2e-mock", app_secret="s", base_url=base_url,
            uploads_dir="/tmp",
        )
        adapter = FeishuAdapter(cfg)

        # Note: key is "msg_id" (matches Elixir emit post-D2 fix)
        result = await adapter.on_directive(
            "react", {"msg_id": "om_mock_1", "emoji_type": "THUMBSUP"}
        )
        assert result["ok"] is True, result

        with urlopen(f"{base_url}/reactions", timeout=5) as resp:
            listing = json.loads(resp.read())
        assert len(listing) == 1
        assert listing[0]["message_id"] == "om_mock_1"
        assert listing[0]["emoji_type"] == "THUMBSUP"
    finally:
        await mock.stop()
```

- [ ] **Step 6: Run — expect fail (live branch calls lark_oapi which doesn't exist in test env / errors)**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor && \
  uv run --project py pytest py/tests/adapter_runners/test_feishu_react.py -v
```

Expected: FAIL — either import error for lark_oapi or connection failure.

- [ ] **Step 7: Add mock branch to `_react`**

In `adapter.py`, replace the body of `_react` (around line 429):

```python
def _react(self, args: dict[str, Any]) -> dict[str, Any]:
    """Create a reaction on a message. Mock path: POST to mock_feishu
    when base_url is 127.0.0.1/localhost. Live path: lark_oapi (PRD 04 F08)."""
    msg_id = args["msg_id"]
    emoji_type = args["emoji_type"]

    base_url = getattr(self._config, "base_url", "") or ""
    if base_url.startswith(("http://127.0.0.1", "http://localhost")):
        return self._react_mock(base_url, msg_id, emoji_type)

    import lark_oapi.api.im.v1 as im_v1
    request = (
        im_v1.CreateMessageReactionRequest.builder()
        .message_id(msg_id)
        .request_body(
            im_v1.CreateMessageReactionRequestBody.builder()
            .reaction_type(
                im_v1.Emoji.builder().emoji_type(emoji_type).build()
            )
            .build()
        )
        .build()
    )
    response = self.client().im.v1.message.reaction.create(request)
    if response.success():
        reaction_id = getattr(response.data, "reaction_id", None) or getattr(
            response.data, "message_id", ""
        )
        return {"ok": True, "result": {"reaction_id": reaction_id}}
    return _lark_failure(response, "react failed")


def _react_mock(
    self, base_url: str, msg_id: str, emoji_type: str
) -> dict[str, Any]:
    import urllib.error
    import urllib.request

    body = json.dumps({
        "reaction_type": {"emoji_type": emoji_type},
    }).encode("utf-8")
    req = urllib.request.Request(
        f"{base_url}/open-apis/im/v1/messages/{msg_id}/reactions",
        data=body,
        headers={"content-type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read())
            return {"ok": True, "result": data.get("data") or {}}
    except urllib.error.URLError as exc:
        return {"ok": False, "error": f"mock react failed: {exc}"}
```

- [ ] **Step 8: Run react test — expect pass**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor && \
  uv run --project py pytest py/tests/adapter_runners/test_feishu_react.py -v
```

Expected: PASS.

- [ ] **Step 9: Run the full adapter_runners test module to confirm no regression**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor && \
  uv run --project py pytest py/tests/adapter_runners/ -v
```

Expected: PASS (all existing tests + 3 new).

- [ ] **Step 10: Commit**

```bash
git add adapters/feishu/src/esr_feishu/adapter.py \
        py/tests/adapter_runners/test_feishu_send_file.py \
        py/tests/adapter_runners/test_feishu_react.py
git commit -m "$(cat <<'EOF'
feat(esr_feishu): _send_file + _react mock branches (Task C)

Implements α (base64 in-band) wire shape for send_file per spec §6;
adds mock-mode branch to _react so scenario 01 can assert via
/reactions without live lark_oapi. Pinned to T0 §3 and §4a.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task D1: `channel_adapter` plumbing (SessionRouter → PeerFactory → FeishuChatProxy)

**Goal:** Introduce a `channel_adapter` value derived from `proxies[].target` regex and thread it end-to-end so the session's `FeishuChatProxy` state-map carries it. This unblocks D2 (the `peer_server.ex` read). **No change yet to `peer_server.ex`.**

**Files:**
- Modify: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr/session_router.ex`
- Modify: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr/peers/feishu_chat_proxy.ex`
- Create: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/test/esr/session_router_channel_adapter_test.exs`

**Nit-handling carry-in from review:**
- **Regex greediness:** the named test case `"admin::feishu_app_adapter_default" → "feishu_app"` (not `"feishu"`) is the first assertion in Step 1. The test name makes the decision explicit: `"regex captures entire family incl. underscored suffix (feishu_app)"`.
- **FeishuChatProxy ctx-copy is a NEW pattern, not a replica:** today `init/1` stashes the entire `proxy_ctx` as an opaque blob in state (line 32 of `feishu_chat_proxy.ex`). Step 5 explicitly lifts one field out of that blob into the state map — the docstring/commit message frame it as "new pattern: per-peer field-lift from ctx into thread-state."

- [ ] **Step 1: Write failing test — regex parsing + four named cases**

Create `runtime/test/esr/session_router_channel_adapter_test.exs`:

```elixir
defmodule Esr.SessionRouterChannelAdapterTest do
  @moduledoc """
  Task D1 — verify `channel_adapter` is extracted from the
  `proxies[].target` string and propagated into session params.
  Named cases cover the four rows in T0 §1.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Esr.SessionRouter

  describe "parse_channel_adapter/1" do
    test "regex captures entire family incl. underscored suffix (feishu_app)" do
      target = "admin::feishu_app_adapter_default"
      assert SessionRouter.parse_channel_adapter(target) == {:ok, "feishu_app"}
    end

    test "alphanumeric app_id does not bleed into family capture" do
      assert SessionRouter.parse_channel_adapter(
               "admin::feishu_app_adapter_e2e-mock"
             ) == {:ok, "feishu_app"}
    end

    test "multi-underscore family captured whole (slack_v2)" do
      assert SessionRouter.parse_channel_adapter(
               "admin::slack_v2_adapter_acme"
             ) == {:ok, "slack_v2"}
    end

    test "non-matching target falls back to feishu and logs a warning" do
      log =
        capture_log(fn ->
          assert SessionRouter.parse_channel_adapter(
                   "admin::malformed-no-underscore"
                 ) == {:ok, "feishu"}
        end)

      assert log =~ "channel_adapter: non-matching proxy target"
    end
  end
end
```

- [ ] **Step 2: Run — expect fail (`parse_channel_adapter/1` undefined)**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime && \
  mix test test/esr/session_router_channel_adapter_test.exs
```

Expected: FAIL — `function Esr.SessionRouter.parse_channel_adapter/1 is undefined`.

- [ ] **Step 3: Add `parse_channel_adapter/1` as a public helper in `session_router.ex`**

In `runtime/lib/esr/session_router.ex`, add a new public function (place near the other helpers, e.g. after `extract_principal/1`):

```elixir
@channel_adapter_regex ~r/^admin::([a-z_]+)_adapter_.*$/

@doc """
Extract the channel adapter family from a proxy target string.

Regex captures the entire token before `_adapter_`, so
`"admin::feishu_app_adapter_default"` returns `"feishu_app"` (the family
includes underscored suffixes). Non-matching strings fall back to
`"feishu"` and emit a `Logger.warning`.
"""
@spec parse_channel_adapter(String.t()) :: {:ok, String.t()}
def parse_channel_adapter(target) when is_binary(target) do
  case Regex.run(@channel_adapter_regex, target) do
    [_, family] ->
      {:ok, family}

    _ ->
      Logger.warning(
        "channel_adapter: non-matching proxy target target=#{inspect(target)} " <>
          "falling back to feishu"
      )

      {:ok, "feishu"}
  end
end
```

Ensure `require Logger` is already at the top of the file (it is — line 9 of the current file).

- [ ] **Step 4: Run test — expect pass**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime && \
  mix test test/esr/session_router_channel_adapter_test.exs
```

Expected: PASS (4 tests).

- [ ] **Step 5: Extend the test file with an end-to-end-through-do_create case (still should pass the existing 4, but adds a spawn-path case)**

Append to `session_router_channel_adapter_test.exs`:

```elixir
  describe "do_create/1 params thread channel_adapter" do
    test "FeishuAppProxy target seeds :channel_adapter in ctx" do
      # The `build_ctx` clause for FeishuAppProxy is the seed point.
      # We exercise it directly (it's a private helper but tested
      # via a narrow public hook: see `SessionRouter.build_ctx_for_test/2`).
      spec = %{
        "impl" => "Esr.Peers.FeishuAppProxy",
        "target" => "admin::feishu_app_adapter_e2e-mock"
      }

      ctx = SessionRouter.build_ctx_for_test(spec, %{app_id: "e2e-mock"})
      assert ctx[:channel_adapter] == "feishu_app"
      assert ctx[:app_id] == "e2e-mock"
    end

    test "non-FeishuAppProxy spec returns ctx without :channel_adapter" do
      spec = %{"impl" => "Esr.Peers.CCProxy"}
      ctx = SessionRouter.build_ctx_for_test(spec, %{})
      refute Map.has_key?(ctx, :channel_adapter)
    end
  end
```

- [ ] **Step 6: Run — expect fail (`build_ctx_for_test/2` undefined + the clause doesn't add `:channel_adapter` yet)**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime && \
  mix test test/esr/session_router_channel_adapter_test.exs
```

Expected: FAIL on the 5th test.

- [ ] **Step 7: Extend `build_ctx/2` for FeishuAppProxy AND expose a narrow test hook**

In `session_router.ex`, replace the existing `build_ctx/2` clause for FeishuAppProxy (currently line 363):

```elixir
defp build_ctx(%{"impl" => "Esr.Peers.FeishuAppProxy", "target" => tgt}, params) do
  app_id = get_param(params, :app_id) || "default"
  expanded = String.replace(tgt, "${app_id}", app_id)

  sym =
    case String.split(expanded, "::", parts: 2) do
      [_, admin_peer_name] -> String.to_atom(admin_peer_name)
      [admin_peer_name] -> String.to_atom(admin_peer_name)
    end

  target_pid =
    case safe_admin_peer(sym) do
      {:ok, pid} -> pid
      _ -> nil
    end

  {:ok, channel_adapter} = parse_channel_adapter(expanded)

  %{
    principal_id: get_param(params, :principal_id),
    target_pid: target_pid,
    app_id: app_id,
    channel_adapter: channel_adapter
  }
end
```

Add a test hook directly below the private helpers (namespace-local, test-only convention):

```elixir
@doc false
# Test-only shim: lets D1's ExUnit reach the private build_ctx/2
# clauses without smuggling in a whole Session. Keep the shim narrow —
# delegates directly to the same private function.
def build_ctx_for_test(spec, params), do: build_ctx(spec, params)
```

- [ ] **Step 8: Run — expect pass (all 6 tests)**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime && \
  mix test test/esr/session_router_channel_adapter_test.exs
```

Expected: PASS (6 tests).

- [ ] **Step 9: Extend `spawn_one/5` so ctx carries through to params for downstream peers**

Today `spawn_one/5` computes `ctx = build_ctx(spec, params)` and passes ctx to `PeerFactory.spawn_peer`. The ctx map is fine; but we *also* want downstream peers (`FeishuChatProxy`) to see `channel_adapter` even though `build_ctx/2` for FeishuChatProxy's spec (`Esr.Peers.FeishuChatProxy`) currently falls through to the default clause (line 410: `defp build_ctx(_, _params), do: %{}`).

Patch the default clause to lift `channel_adapter` from params if present:

```elixir
defp build_ctx(_, params) do
  case get_param(params, :channel_adapter) do
    nil -> %{}
    family -> %{channel_adapter: family}
  end
end
```

AND at the top of `spawn_pipeline/3`, pre-compute `channel_adapter` from the first FeishuAppProxy proxy target and stamp it into `params` so later `spawn_one/5` calls see it. Insert at the start of `spawn_pipeline/3` (current line 294):

```elixir
defp spawn_pipeline(session_id, agent_def, params) do
  inbound = agent_def.pipeline.inbound || []
  proxies = agent_def.proxies || []

  # D1: lift `channel_adapter` from the first matching proxy target so
  # downstream peers (FeishuChatProxy, CCProcess) see it via their ctx.
  channel_adapter =
    proxies
    |> Enum.find_value(fn
      %{"target" => tgt} when is_binary(tgt) ->
        {:ok, fam} = parse_channel_adapter(tgt)
        fam

      _ ->
        nil
    end)
    |> Kernel.||("feishu")

  params = Map.put(params, :channel_adapter, channel_adapter)

  try do
    # ... rest of the existing function unchanged ...
```

- [ ] **Step 10: Extend the test file with a spawn-pipeline-level assertion**

Append:

```elixir
  describe "spawn_pipeline/3 stamps :channel_adapter into params" do
    test "agent with FeishuAppProxy lifts channel_adapter=feishu_app" do
      # Drive do_create indirectly: build a fake agent_def and call the
      # exposed shim. A full session spawn is overkill for this test;
      # the stamp step is the observable the test targets.
      agent_def = %{
        pipeline: %{inbound: []},
        proxies: [
          %{"name" => "feishu_app_proxy",
            "impl" => "Esr.Peers.FeishuAppProxy",
            "target" => "admin::feishu_app_adapter_default"}
        ]
      }

      params = SessionRouter.stamp_channel_adapter_for_test(agent_def, %{})
      assert params[:channel_adapter] == "feishu_app"
    end

    test "agent with no proxies falls back to feishu" do
      agent_def = %{pipeline: %{inbound: []}, proxies: []}
      params = SessionRouter.stamp_channel_adapter_for_test(agent_def, %{})
      assert params[:channel_adapter] == "feishu"
    end
  end
```

Then expose the shim in `session_router.ex` alongside `build_ctx_for_test/2`:

```elixir
@doc false
def stamp_channel_adapter_for_test(agent_def, params) do
  proxies = agent_def.proxies || []

  channel_adapter =
    proxies
    |> Enum.find_value(fn
      %{"target" => tgt} when is_binary(tgt) ->
        {:ok, fam} = parse_channel_adapter(tgt)
        fam

      _ ->
        nil
    end)
    |> Kernel.||("feishu")

  Map.put(params, :channel_adapter, channel_adapter)
end
```

And refactor `spawn_pipeline/3` to call the same shim (DRY):

```elixir
defp spawn_pipeline(session_id, agent_def, params) do
  inbound = agent_def.pipeline.inbound || []
  proxies = agent_def.proxies || []
  params = stamp_channel_adapter_for_test(agent_def, params)

  try do
    # ... original body unchanged ...
```

- [ ] **Step 11: Run all 8 D1 tests — expect pass**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime && \
  mix test test/esr/session_router_channel_adapter_test.exs
```

Expected: PASS (8 tests).

- [ ] **Step 12: Update `FeishuChatProxy.init/1` to lift `ctx.channel_adapter` into state (NEW per-peer field-lift pattern)**

In `runtime/lib/esr/peers/feishu_chat_proxy.ex`, replace `init/1` (lines 26-36):

```elixir
@impl GenServer
def init(args) do
  ctx = Map.get(args, :proxy_ctx, %{})

  state = %{
    session_id: Map.fetch!(args, :session_id),
    chat_id: Map.fetch!(args, :chat_id),
    thread_id: Map.fetch!(args, :thread_id),
    neighbors: Map.get(args, :neighbors, []),
    proxy_ctx: ctx,
    # D1 new pattern — explicitly lift a ctx field into state so
    # downstream peers reading the thread-state map (e.g. PeerServer.
    # build_emit_for_tool) see a typed, named slot instead of reaching
    # into the opaque proxy_ctx blob. Fallback "feishu" matches the
    # top-level spawn_pipeline default (session_router.ex).
    "channel_adapter" => Map.get(ctx, :channel_adapter) || "feishu"
  }

  {:ok, state}
end
```

Note the mixed-key map (`"channel_adapter"` is string-keyed to match the D2 consumer's read via `Map.get(thread_state, "channel_adapter", ...)`; the other keys stay atom-keyed because existing code reads them that way). This is the cleanest bridge that avoids rewriting every existing reader.

- [ ] **Step 13: Write a quick proxy-init test to pin the new state shape**

Append to `runtime/test/esr/peers/feishu_chat_proxy_test.exs` (the file exists — insert a new `describe` block at the bottom, inside the outer `defmodule ... do`):

```elixir
  describe "channel_adapter lifted from ctx (D1)" do
    test "init/1 stores ctx.channel_adapter under string key in state" do
      args = %{
        session_id: "s1",
        chat_id: "oc_x",
        thread_id: "tg_x",
        neighbors: [],
        proxy_ctx: %{channel_adapter: "feishu_app"}
      }

      {:ok, state} = Esr.Peers.FeishuChatProxy.init(args)
      assert Map.get(state, "channel_adapter") == "feishu_app"
    end

    test "init/1 falls back to feishu when ctx is missing the key" do
      args = %{
        session_id: "s1",
        chat_id: "oc_x",
        thread_id: "tg_x",
        neighbors: [],
        proxy_ctx: %{}
      }

      {:ok, state} = Esr.Peers.FeishuChatProxy.init(args)
      assert Map.get(state, "channel_adapter") == "feishu"
    end
  end
```

- [ ] **Step 14: Run proxy test — expect pass**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime && \
  mix test test/esr/peers/feishu_chat_proxy_test.exs
```

Expected: PASS (new 2 tests + any pre-existing).

- [ ] **Step 15: Run the full mix test suite to catch regressions from the spawn_pipeline refactor**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime && \
  mix test
```

Expected: PASS (unchanged pre-existing count + 8 new from D1).

- [ ] **Step 16: Commit**

```bash
git add runtime/lib/esr/session_router.ex \
        runtime/lib/esr/peers/feishu_chat_proxy.ex \
        runtime/test/esr/session_router_channel_adapter_test.exs \
        runtime/test/esr/peers/feishu_chat_proxy_test.exs
git commit -m "$(cat <<'EOF'
feat(session_router): plumb channel_adapter end-to-end (Task D1)

Parse proxies[].target with ~r/^admin::([a-z_]+)_adapter_.*$/ (accepts
"feishu_app" as the family per T0 §1), thread the value through
spawn_pipeline → build_ctx → PeerFactory → FeishuChatProxy.init/1.

FeishuChatProxy.init/1 now explicitly lifts ctx.channel_adapter into
state under the string key "channel_adapter" — NEW per-peer field-lift
pattern (prior convention stashed proxy_ctx as an opaque blob).

D2 will consume state["channel_adapter"] in peer_server.ex.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task D2: `peer_server.ex` emit builder fixes + `msg_id` key rename + α send_file shape

**Goal:** Consume `session_channel_adapter(state)` in the three emit builders (reply/react/send_file); rename `message_id`→`msg_id` in the react emit (spec §5.1 pre-existing bug); rewrite `send_file` emit to the α shape (§6.2).

**Files:**
- Modify: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr/peer_server.ex`
- Modify: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/test/esr/peer_server_test.exs` (or create a new focused test file if the existing one is crowded; plan assumes extending the existing file)

**Depends on:** D1 committed (so state can be populated when tests construct a `%PeerServer{}`).

- [ ] **Step 1: Write failing tests for all three emit shapes**

Append to `runtime/test/esr/peer_server_test.exs` (at the bottom, inside the `defmodule ... do`):

```elixir
  describe "build_emit_for_tool/3 reads channel_adapter from state (D2)" do
    test "reply emit uses state.channel_adapter when set" do
      state = %Esr.PeerServer{
        actor_id: "a",
        actor_type: "cc_process",
        handler_module: "x",
        state: %{"channel_adapter" => "feishu_app"}
      }

      {:ok, emit} =
        Esr.PeerServer.build_emit_for_tool_for_test(
          "reply", %{"chat_id" => "oc_1", "text" => "hi"}, state
        )

      assert emit["adapter"] == "feishu_app"
      assert emit["action"] == "send_message"
      assert emit["args"] == %{"chat_id" => "oc_1", "content" => "hi"}
    end

    test "reply emit falls back to feishu when state lacks the slot" do
      state = %Esr.PeerServer{
        actor_id: "a",
        actor_type: "cc_process",
        handler_module: "x",
        state: %{}
      }

      {:ok, emit} =
        Esr.PeerServer.build_emit_for_tool_for_test(
          "reply", %{"chat_id" => "oc_1", "text" => "hi"}, state
        )

      assert emit["adapter"] == "feishu"
    end

    test "react emit args key is msg_id (was message_id — §5.1 bug fix)" do
      state = %Esr.PeerServer{
        actor_id: "a",
        actor_type: "cc_process",
        handler_module: "x",
        state: %{"channel_adapter" => "feishu_app"}
      }

      {:ok, emit} =
        Esr.PeerServer.build_emit_for_tool_for_test(
          "react",
          %{"message_id" => "om_1", "emoji_type" => "THUMBSUP"},
          state
        )

      assert emit["adapter"] == "feishu_app"
      assert emit["args"] == %{"msg_id" => "om_1", "emoji_type" => "THUMBSUP"}
    end

    test "send_file emit encodes bytes as base64 with sha256 (α shape)" do
      tmp = Path.join(System.tmp_dir!(), "d2_probe_#{System.unique_integer([:positive])}.txt")
      File.write!(tmp, "hello D2")

      state = %Esr.PeerServer{
        actor_id: "a",
        actor_type: "cc_process",
        handler_module: "x",
        state: %{"channel_adapter" => "feishu_app"}
      }

      {:ok, emit} =
        Esr.PeerServer.build_emit_for_tool_for_test(
          "send_file",
          %{"chat_id" => "oc_1", "file_path" => tmp},
          state
        )

      assert emit["adapter"] == "feishu_app"
      assert emit["args"]["chat_id"] == "oc_1"
      assert emit["args"]["file_name"] == Path.basename(tmp)
      assert emit["args"]["content_b64"] == Base.encode64("hello D2")
      assert emit["args"]["sha256"] ==
               :crypto.hash(:sha256, "hello D2") |> Base.encode16(case: :lower)

      File.rm!(tmp)
    end

    test "send_file emit returns error tuple when file cannot be read" do
      state = %Esr.PeerServer{
        actor_id: "a",
        actor_type: "cc_process",
        handler_module: "x",
        state: %{"channel_adapter" => "feishu_app"}
      }

      assert {:error, msg} =
               Esr.PeerServer.build_emit_for_tool_for_test(
                 "send_file",
                 %{"chat_id" => "oc_1", "file_path" => "/nonexistent/path"},
                 state
               )

      assert msg =~ "send_file cannot read"
    end
  end
```

- [ ] **Step 2: Run — expect fail (`build_emit_for_tool_for_test/3` missing + behaviour mismatch)**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime && \
  mix test test/esr/peer_server_test.exs --only describe:"build_emit_for_tool/3 reads channel_adapter from state (D2)"
```

Expected: FAIL — undefined function.

- [ ] **Step 3: Patch `peer_server.ex` — add helper, update three clauses, expose test shim**

In `runtime/lib/esr/peer_server.ex`:

**3a.** Add the helper (place near other `defp` helpers, e.g. just above `build_emit_for_tool`):

```elixir
# D2: read the session's bound channel adapter from the thread-state
# map. D1 seeds state["channel_adapter"] in FeishuChatProxy.init/1
# (and downstream peers copy it forward). Missing slot → "feishu"
# fallback (§4.2 deprecated — removed once seeded path is live per
# spec §14 item 2).
defp session_channel_adapter(%__MODULE__{state: thread_state})
     when is_map(thread_state) do
  Map.get(thread_state, "channel_adapter", "feishu")
end

defp session_channel_adapter(_), do: "feishu"
```

**3b.** Replace the three `build_emit_for_tool` clauses (lines 709-756):

```elixir
defp build_emit_for_tool("reply", args, state) do
  case args do
    %{"chat_id" => chat_id, "text" => text}
    when is_binary(chat_id) and is_binary(text) ->
      {:ok,
       %{
         "type" => "emit",
         "adapter" => session_channel_adapter(state),
         "action" => "send_message",
         "args" => %{"chat_id" => chat_id, "content" => text}
       }}

    _ ->
      {:error, "reply requires chat_id + text"}
  end
end

defp build_emit_for_tool("react", args, state) do
  case args do
    %{"message_id" => mid, "emoji_type" => emoji} ->
      {:ok,
       %{
         "type" => "emit",
         "adapter" => session_channel_adapter(state),
         "action" => "react",
         # D2: input key "message_id" (CC's MCP tool schema unchanged);
         # emit arg key "msg_id" (matches adapter.py _react/_pin/_unpin
         # convention). §5.1 pre-existing bug.
         "args" => %{"msg_id" => mid, "emoji_type" => emoji}
       }}

    _ ->
      {:error, "react requires message_id + emoji_type"}
  end
end

defp build_emit_for_tool("send_file", args, state) do
  case args do
    %{"chat_id" => cid, "file_path" => fp} when is_binary(fp) ->
      case File.read(fp) do
        {:ok, bytes} ->
          {:ok,
           %{
             "type" => "emit",
             "adapter" => session_channel_adapter(state),
             "action" => "send_file",
             "args" => %{
               "chat_id" => cid,
               "file_name" => Path.basename(fp),
               "content_b64" => Base.encode64(bytes),
               "sha256" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
             }
           }}

        {:error, reason} ->
          {:error, "send_file cannot read #{fp}: #{inspect(reason)}"}
      end

    _ ->
      {:error, "send_file requires chat_id + file_path"}
  end
end
```

**3c.** Note the `_echo` clause (line 758) currently calls `build_emit_for_tool("reply", ..., nil)` — that now crashes because the new reply clause calls `session_channel_adapter(state)` which no longer matches on `nil`. The `session_channel_adapter(_)` fallback covers this; `_echo` still works and returns `"feishu"` as the adapter (acceptable — `_echo` is diagnostic-only and the echo round-trip doesn't care about the adapter label in tests).

**3d.** Add the test shim at module level (near the existing public `describe/1` function, around line 97):

```elixir
@doc false
# D2 test hook — exercises the three private emit builders without
# standing up a live GenServer. Signature identical to the private
# function; callers construct a fake %__MODULE__{} struct.
def build_emit_for_tool_for_test(tool, args, state) do
  build_emit_for_tool(tool, args, state)
end
```

- [ ] **Step 4: Run D2 tests — expect pass**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime && \
  mix test test/esr/peer_server_test.exs --only describe:"build_emit_for_tool/3 reads channel_adapter from state (D2)"
```

Expected: PASS (5 tests).

- [ ] **Step 5: Run the full peer_server_test suite — verify no regressions in the other emit-related tests**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime && \
  mix test test/esr/peer_server_test.exs \
           test/esr/peer_server_tool_invoke_test.exs \
           test/esr/peer_server_emit_ack_test.exs
```

Expected: PASS (all existing tests remain green; some may have hardcoded `"feishu"` in assertions — if so, update those assertions to match the state-driven value and note the change in the commit message).

- [ ] **Step 6: If the existing peer_server tool-invoke tests assert `"adapter" => "feishu"` with a state that lacks the slot, leave them unchanged (fallback covers this case). If they assert with state that has the slot set, update the assertion to the populated value.**

Run `grep -n '"adapter" => "feishu"' runtime/test/esr/peer_server*.exs` — for each hit, inspect the surrounding state literal:
- State has `channel_adapter` set → update assertion to match.
- State has no `channel_adapter` → assertion stays `"feishu"` (fallback path).

- [ ] **Step 7: Run full mix test — expect pass**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime && \
  mix test
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add runtime/lib/esr/peer_server.ex runtime/test/esr/peer_server_test.exs
git commit -m "$(cat <<'EOF'
feat(peer_server): consume channel_adapter + fix msg_id bug + α send_file (Task D2)

- Replace three hardcoded "adapter" => "feishu" literals in
  build_emit_for_tool with session_channel_adapter(state) reads.
- Fix pre-existing bug in react emit: key was "message_id", adapter.py
  reads "msg_id" — Elixir source now emits "msg_id" (§5.1).
- Rewrite send_file emit to α (base64 in-band) shape with sha256
  checksum (§6.2). File.read failures surface as {:error, ...}.
- session_channel_adapter/1 fallback to "feishu" preserves existing
  behaviour for sessions spawned before D1's seed path lands.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task J1: `tmux_socket` env plumbing

**Goal:** `ESR_E2E_TMUX_SOCK=/path` in the shell before `esrd` boots → every tmux_process spawn uses that socket, without any per-call plumbing.

**Files:**
- Modify: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr/application.ex`
- Modify: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr/peers/tmux_process.ex`
- Modify: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/test/esr/peers/tmux_process_test.exs`

**Independent of:** D1, D2, K1, K2. Can be run in parallel with D1.

- [ ] **Step 1: Write failing test — observable invariant (ESR_E2E_TMUX_SOCK → spawn_args)**

Append to `runtime/test/esr/peers/tmux_process_test.exs` (inside the outer `defmodule ... do`, at the bottom):

```elixir
  describe "spawn_args/1 honours :tmux_socket_override app env (J1)" do
    setup do
      prev = Application.get_env(:esr, :tmux_socket_override)
      on_exit(fn ->
        if prev == nil do
          Application.delete_env(:esr, :tmux_socket_override)
        else
          Application.put_env(:esr, :tmux_socket_override, prev)
        end
      end)

      :ok
    end

    test "set override is picked up when params omit :tmux_socket" do
      Application.put_env(:esr, :tmux_socket_override, "/tmp/override.sock")
      args = Esr.Peers.TmuxProcess.spawn_args(%{})
      assert args.tmux_socket == "/tmp/override.sock"
    end

    test "explicit :tmux_socket in params wins over override" do
      Application.put_env(:esr, :tmux_socket_override, "/tmp/override.sock")
      args = Esr.Peers.TmuxProcess.spawn_args(%{tmux_socket: "/tmp/explicit.sock"})
      assert args.tmux_socket == "/tmp/explicit.sock"
    end

    test "no override + no param yields no :tmux_socket key" do
      Application.delete_env(:esr, :tmux_socket_override)
      args = Esr.Peers.TmuxProcess.spawn_args(%{})
      refute Map.has_key?(args, :tmux_socket)
    end

    test "boot-time env reader: ESR_E2E_TMUX_SOCK → :tmux_socket_override" do
      # Exercise the boot helper directly so we don't need to restart
      # the Application — Esr.Application.apply_tmux_socket_env/0 is a
      # pure function exposed for tests.
      System.put_env("ESR_E2E_TMUX_SOCK", "/tmp/boot.sock")
      try do
        Esr.Application.apply_tmux_socket_env()
        assert Application.get_env(:esr, :tmux_socket_override) == "/tmp/boot.sock"
      after
        System.delete_env("ESR_E2E_TMUX_SOCK")
        Application.delete_env(:esr, :tmux_socket_override)
      end
    end

    test "boot-time reader: empty ESR_E2E_TMUX_SOCK is a no-op" do
      System.put_env("ESR_E2E_TMUX_SOCK", "")
      Application.delete_env(:esr, :tmux_socket_override)
      try do
        Esr.Application.apply_tmux_socket_env()
        assert Application.get_env(:esr, :tmux_socket_override) == nil
      after
        System.delete_env("ESR_E2E_TMUX_SOCK")
      end
    end
  end
```

- [ ] **Step 2: Run — expect fail**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime && \
  mix test test/esr/peers/tmux_process_test.exs --only describe:"spawn_args/1 honours :tmux_socket_override app env (J1)"
```

Expected: FAIL — `Esr.Application.apply_tmux_socket_env/0 undefined` + override not respected by spawn_args.

- [ ] **Step 3: Extend `TmuxProcess.spawn_args/1` to merge the override**

Replace the function (lines 68-80 of `tmux_process.ex`):

```elixir
@impl Esr.Peer
def spawn_args(params) do
  # Optional tmux_socket for test isolation: if caller passes
  # `tmux_socket: "/tmp/…"`, TmuxProcess runs under that socket; if the
  # application env `:esr, :tmux_socket_override` is set (J1 — driven
  # by ESR_E2E_TMUX_SOCK at boot), use that as a fallback.
  name = "esr_cc_#{:erlang.unique_integer([:positive])}"
  base = %{session_name: name, dir: Esr.Peer.get_param(params, :dir) || "/tmp"}

  case Esr.Peer.get_param(params, :tmux_socket) ||
         Application.get_env(:esr, :tmux_socket_override) do
    nil -> base
    path when is_binary(path) -> Map.put(base, :tmux_socket, path)
  end
end
```

- [ ] **Step 4: Add `apply_tmux_socket_env/0` to `Esr.Application`**

In `runtime/lib/esr/application.ex`, inside `def start(_type, _args)`, **before** the `children = [...]` list, call the new helper:

```elixir
@impl Application
def start(_type, _args) do
  apply_tmux_socket_env()

  children = [
    # ... existing list unchanged ...
```

And add the public function (at module level, below `start/2`):

```elixir
@doc """
Read `ESR_E2E_TMUX_SOCK` env var and, when set to a non-empty value,
stash it under `{:esr, :tmux_socket_override}`. TmuxProcess.spawn_args/1
consults the override when its caller didn't supply `:tmux_socket`.

Exposed publicly for test access — pure function; idempotent.
"""
@spec apply_tmux_socket_env() :: :ok
def apply_tmux_socket_env do
  case System.get_env("ESR_E2E_TMUX_SOCK") do
    nil -> :ok
    "" -> :ok
    path -> Application.put_env(:esr, :tmux_socket_override, path)
  end
end
```

- [ ] **Step 5: Run the J1 describe block — expect pass**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime && \
  mix test test/esr/peers/tmux_process_test.exs --only describe:"spawn_args/1 honours :tmux_socket_override app env (J1)"
```

Expected: PASS (5 tests).

- [ ] **Step 6: Run full mix test to confirm no regression in application boot**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime && \
  mix test
```

Expected: PASS.

- [ ] **Step 7: Add an integration-level observable test — start esrd with ESR_E2E_TMUX_SOCK set and assert the live tmux_process's state carries the socket**

This is the "non-obvious assertion" the plan-writer brief asked for. Append to `runtime/test/esr/peers/tmux_process_test.exs`:

```elixir
  describe "end-to-end ESR_E2E_TMUX_SOCK observable (J1 integration)" do
    test "boot + spawn assert the tmux socket path threads into peer state" do
      # Simulated boot: call apply_tmux_socket_env as the Application
      # does at startup. Then spawn a TmuxProcess and describe its state.
      path = "/tmp/e2e-tmux-int-#{System.unique_integer([:positive])}.sock"
      System.put_env("ESR_E2E_TMUX_SOCK", path)
      try do
        Esr.Application.apply_tmux_socket_env()
        args = Esr.Peers.TmuxProcess.spawn_args(%{})
        assert args[:tmux_socket] == path
      after
        System.delete_env("ESR_E2E_TMUX_SOCK")
        Application.delete_env(:esr, :tmux_socket_override)
      end
    end
  end
```

- [ ] **Step 8: Run the integration test — expect pass**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime && \
  mix test test/esr/peers/tmux_process_test.exs --only describe:"end-to-end ESR_E2E_TMUX_SOCK observable (J1 integration)"
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add runtime/lib/esr/application.ex \
        runtime/lib/esr/peers/tmux_process.ex \
        runtime/test/esr/peers/tmux_process_test.exs
git commit -m "$(cat <<'EOF'
feat(application): ESR_E2E_TMUX_SOCK → :tmux_socket_override (Task J1)

Application.apply_tmux_socket_env/0 reads the env var at boot and
stashes the value under {:esr, :tmux_socket_override}; TmuxProcess.
spawn_args/1 falls back to that override when callers don't supply
:tmux_socket explicitly. Enables run-scoped tmux isolation in the e2e
scripts without per-spawn plumbing. Pinned to T0 §5.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task F: scenario 01 — single-user create → react → send_file → end

**Goal:** One bash script covering the first 6 user-steps of §9 under isolated cleanup.

**Files:**
- Create: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/tests/e2e/scenarios/01_single_user_create_and_end.sh`

**Depends on:** A (common.sh + fixture), B (mock endpoints), C (adapter), D2 (msg_id fix), J1 (tmux socket).

- [ ] **Step 1: Write a failing script stub — empty body, only sources common.sh**

```bash
#!/usr/bin/env bash
# PR-7 scenario 01 — single user, create → react → send_file → end.
# See docs/superpowers/specs/2026-04-23-pr7-e2e-feishu-to-cc-design.md §3.2
# and §9 coverage matrix user-steps 1-6.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

echo "scenario 01: not yet implemented"
exit 1  # forcing function — removed in Step 3
```

- [ ] **Step 2: Run — expect fail**

```bash
bash /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/tests/e2e/scenarios/01_single_user_create_and_end.sh
```

Expected: exit 1 with "not yet implemented".

- [ ] **Step 3: Flesh out the body — 6 user-steps + assertions**

Replace the script body:

```bash
#!/usr/bin/env bash
# PR-7 scenario 01 — single user, create → reply → react → send_file → end.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

BASELINE=$(e2e_tmp_baseline_snapshot)

# --- setup ------------------------------------------------------------
load_agent_yaml
start_mock_feishu
start_esrd
register_feishu_adapter

# --- user-step 1: create session --------------------------------------
uv run --project "${_E2E_REPO_ROOT}/py" esr cmd run \
  "/new-session esr-dev tag=single app_id=e2e-mock"
# Wait until the cc:single actor appears.
for _ in $(seq 1 50); do
  if uv run --project "${_E2E_REPO_ROOT}/py" esr actors list 2>/dev/null \
       | grep -q "cc:single"; then
    break
  fi
  sleep 0.1
done
assert_actors_list_has "cc:single" "user-step 1: cc:single peer spawned"

# --- user-step 2: inbound plain message → CC replies ------------------
INBOUND_MSG_ID=$(curl -sS -X POST \
  -H 'content-type: application/json' \
  -d '{"chat_id":"oc_mock_single","sender_open_id":"ou_e2e","content_text":"hello"}' \
  "http://127.0.0.1:${MOCK_FEISHU_PORT}/push_inbound" \
  | jq -r '.message_id')
[[ -n "$INBOUND_MSG_ID" ]] || _fail_with_context "push_inbound did not return message_id"

# Wait for CC's reply to land in mock's sent_messages.
for _ in $(seq 1 100); do
  if curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/sent_messages" \
       | jq -e '.[] | select(.receive_id=="oc_mock_single")' >/dev/null; then
    break
  fi
  sleep 0.1
done
assert_mock_feishu_sent_includes "oc_mock_single" "ack"  # handler's ack substring

# --- user-step 3: CC reacts on inbound --------------------------------
# Depending on agent wiring, CC invokes `react` automatically. Wait for
# the reaction count to reach 1.
for _ in $(seq 1 100); do
  count=$(curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/reactions" \
    | jq --arg mid "$INBOUND_MSG_ID" '[.[] | select(.message_id==$mid)] | length')
  [[ "$count" -ge 1 ]] && break
  sleep 0.1
done
assert_mock_feishu_reactions_count "$INBOUND_MSG_ID" 1

# --- user-step 4: CC sends file ---------------------------------------
EXPECTED_SHA=$(shasum -a 256 "${_E2E_REPO_ROOT}/tests/e2e/fixtures/probe_file.txt" \
  | awk '{print $1}')
# CC invokes send_file via its tool; wait for it to show up.
for _ in $(seq 1 100); do
  if curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/sent_files" \
       | jq -e '.[] | select(.chat_id=="oc_mock_single")' >/dev/null; then
    break
  fi
  sleep 0.1
done
assert_mock_feishu_file_sha "oc_mock_single" "$EXPECTED_SHA"

# --- user-step 5: second message, same session -----------------------
curl -sS -X POST -H 'content-type: application/json' \
  -d '{"chat_id":"oc_mock_single","sender_open_id":"ou_e2e","content_text":"again"}' \
  "http://127.0.0.1:${MOCK_FEISHU_PORT}/push_inbound" >/dev/null
sleep 1
# Same peer, so cc:single still present.
assert_actors_list_has "cc:single" "user-step 5: session persisted after 2nd msg"

# --- user-step 6: end session ----------------------------------------
uv run --project "${_E2E_REPO_ROOT}/py" esr cmd run "/end-session single"
for _ in $(seq 1 50); do
  if ! uv run --project "${_E2E_REPO_ROOT}/py" esr actors list 2>/dev/null \
         | grep -q "cc:single"; then
    break
  fi
  sleep 0.1
done
assert_actors_list_lacks "cc:single" "user-step 6: peer torn down"

# --- user-step 12 (cleanup assertion — deferred until trap runs) ------
# Trap runs after this script exits; assertion on baseline happens in
# the Makefile recipe that also runs `assert_baseline_clean "$BASELINE"`.
# For solo-script runs, export BASELINE so the trap can use it:
export _E2E_BASELINE="$BASELINE"

echo "PASS: scenario 01"
```

- [ ] **Step 4: Run the script against a fresh checkout**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor && \
  bash tests/e2e/scenarios/01_single_user_create_and_end.sh
```

Expected: `PASS: scenario 01` and exit 0. Wall time ≤ 45 s.

**If it fails:** the most likely causes (pre-categorised for the executing subagent):
1. `esr cmd run /new-session` rejects the params → check `admin/commands/session/new.ex` accepts `tag=`+`app_id=`.
2. CC's handler doesn't auto-`react` or auto-`send_file` → the cc_adapter_runner default policy may need a new fixture. If so, open a sub-issue and swap the scenario's assertions to trigger those tools explicitly via `esr cmd run` slashes rather than expecting auto-behaviour. Document the substitution in `docs/notes/pr7-scenario-01-tool-trigger.md` and reference from here.
3. `sha256` mismatch between Python handler (which encodes) and bash (which reads disk) → check the handler reads the probe file from the fixtures dir path the script expects.

- [ ] **Step 5: Commit**

```bash
git add tests/e2e/scenarios/01_single_user_create_and_end.sh
git commit -m "$(cat <<'EOF'
feat(e2e): scenario 01 — single-user create/react/send_file/end (Task F)

Covers §9 user-steps 1-6 + step 12 (cleanup via common.sh trap).
Uses assert_mock_feishu_reactions_count + assert_mock_feishu_file_sha
(new in Task B) + assert_actors_list_has/_lacks.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task G: scenario 02 — two users, concurrent isolation

**Goal:** Two bash subshells each creating their own session and running a probe; the outer script joins via `wait $pid_a $pid_b`; after join, assert cross-isolation (alpha's text absent from beta's sent_messages).

**Files:**
- Create: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/tests/e2e/scenarios/02_two_users_concurrent.sh`

**Depends on:** same as F.

- [ ] **Step 1: Write failing stub**

Same as F Step 1 but with the `02_` filename and a different echo.

- [ ] **Step 2: Run — expect fail.**

- [ ] **Step 3: Flesh out the body**

```bash
#!/usr/bin/env bash
# PR-7 scenario 02 — two concurrent users, session isolation.
# See spec §3.3 + §9 user-steps 7-8.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

load_agent_yaml
start_mock_feishu
start_esrd
register_feishu_adapter

run_user() {
  local tag=$1 chat_id=$2 phrase=$3
  uv run --project "${_E2E_REPO_ROOT}/py" esr cmd run \
    "/new-session esr-dev tag=${tag} app_id=e2e-mock"
  # Wait for the peer
  for _ in $(seq 1 50); do
    if uv run --project "${_E2E_REPO_ROOT}/py" esr actors list 2>/dev/null \
         | grep -q "cc:${tag}"; then
      break
    fi
    sleep 0.1
  done
  barrier_signal "session_ready_${tag}"

  # Parent signals probe_gate_open when BOTH are ready — wait here.
  barrier_wait "probe_gate_open" 15

  curl -sS -X POST -H 'content-type: application/json' \
    -d "{\"chat_id\":\"${chat_id}\",\"sender_open_id\":\"ou_${tag}\",\"content_text\":\"${phrase}\"}" \
    "http://127.0.0.1:${MOCK_FEISHU_PORT}/push_inbound" >/dev/null
  barrier_signal "probe_sent_${tag}"
}

# Launch both subshells in parallel.
run_user "alpha" "oc_mock_A" "probe-alpha-unique" &
PID_A=$!
run_user "beta" "oc_mock_B" "probe-beta-unique" &
PID_B=$!

# Parent waits for both to reach session_ready, then opens the probe gate.
barrier_wait "session_ready_alpha" 30
barrier_wait "session_ready_beta" 30
barrier_signal "probe_gate_open"

# Parent waits for both probes to be sent, then for replies to appear.
barrier_wait "probe_sent_alpha" 10
barrier_wait "probe_sent_beta" 10

# Let CC process inbounds.
for _ in $(seq 1 100); do
  replies_a=$(curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/sent_messages" \
    | jq '[.[] | select(.receive_id=="oc_mock_A")] | length')
  replies_b=$(curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/sent_messages" \
    | jq '[.[] | select(.receive_id=="oc_mock_B")] | length')
  [[ "$replies_a" -ge 1 && "$replies_b" -ge 1 ]] && break
  sleep 0.1
done

# --- isolation assertions --------------------------------------------
SENT=$(curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/sent_messages")
A_BODY=$(echo "$SENT" | jq -r '.[] | select(.receive_id=="oc_mock_A") | .content' | tr '\n' ' ')
B_BODY=$(echo "$SENT" | jq -r '.[] | select(.receive_id=="oc_mock_B") | .content' | tr '\n' ' ')
assert_not_contains "$A_BODY" "probe-beta-unique" "alpha got beta's content"
assert_not_contains "$B_BODY" "probe-alpha-unique" "beta got alpha's content"

# Join subshells.
wait "$PID_A" "$PID_B"

# --- user-step 8: end both -------------------------------------------
uv run --project "${_E2E_REPO_ROOT}/py" esr cmd run "/end-session alpha"
uv run --project "${_E2E_REPO_ROOT}/py" esr cmd run "/end-session beta"
for _ in $(seq 1 50); do
  out=$(uv run --project "${_E2E_REPO_ROOT}/py" esr actors list 2>&1 || true)
  if ! echo "$out" | grep -q "cc:alpha" && ! echo "$out" | grep -q "cc:beta"; then
    break
  fi
  sleep 0.1
done
assert_actors_list_lacks "cc:alpha" "user-step 8a"
assert_actors_list_lacks "cc:beta" "user-step 8b"

echo "PASS: scenario 02"
```

- [ ] **Step 4: Run**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor && \
  bash tests/e2e/scenarios/02_two_users_concurrent.sh
```

Expected: `PASS: scenario 02`. Wall time ≤ 60 s.

- [ ] **Step 5: Commit**

```bash
git add tests/e2e/scenarios/02_two_users_concurrent.sh
git commit -m "$(cat <<'EOF'
feat(e2e): scenario 02 — two-user concurrent isolation (Task G)

Covers §9 user-steps 7-8. Barrier primitives (α wait + β barrier
files) gate the probe send until both sessions are ready, then assert
cross-isolation: alpha's phrase absent from beta's sent_messages and
vice versa.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task H: scenario 03 — tmux attach + edit + detach + CLI `--field` extension

**Goal:** Script attaches to the session's tmux pane, sends keys, reads the pane, ends the session. Requires a small CLI extension to query the live tmux session_name at runtime.

**Files:**
- Create: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/tests/e2e/scenarios/03_tmux_attach_edit.sh`
- Modify: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr_web/cli_channel.ex` (add `--field` support to `cli:actors/inspect`)
- Create or modify: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/test/esr_web/cli_channel_test.exs` (may exist; append if so)

**Depends on:** A, D2, J1.

- [ ] **Step 1: Write failing test for `cli:actors/inspect --field`**

Check whether `runtime/test/esr_web/cli_channel_test.exs` exists. If yes, append; if no, create.

```elixir
defmodule EsrWeb.CliChannelFieldInspectTest do
  @moduledoc """
  Task H — cli:actors/inspect accepts {arg, field} and returns the
  value at the dotted field path from the peer's describe map.
  """
  use ExUnit.Case, async: false

  alias EsrWeb.CliChannel

  # Stub the registry → describe chain by spawning a real PeerServer
  # and registering it. Uses existing Esr.PeerRegistry.
  setup do
    actor_id = "test_actor_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      GenServer.start(
        Esr.PeerServer,
        [
          actor_id: actor_id,
          actor_type: "test",
          handler_module: "x",
          state: %{"session_name" => "esr_cc_42", "channel_adapter" => "feishu_app"}
        ],
        []
      )

    Registry.register(Esr.PeerRegistry, actor_id, nil)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {:ok, actor_id: actor_id}
  end

  test "dispatch returns value at dotted field path", %{actor_id: aid} do
    resp =
      CliChannel.dispatch(
        "cli:actors/inspect",
        %{"arg" => aid, "field" => "state.session_name"}
      )

    assert resp["data"]["field"] == "state.session_name"
    assert resp["data"]["value"] == "esr_cc_42"
  end

  test "missing field path returns structured error", %{actor_id: aid} do
    resp =
      CliChannel.dispatch(
        "cli:actors/inspect",
        %{"arg" => aid, "field" => "state.does_not_exist"}
      )

    assert resp["data"]["error"] == "field not present"
    assert resp["data"]["field"] == "state.does_not_exist"
  end
end
```

- [ ] **Step 2: Run — expect fail (current dispatch ignores `"field"`)**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime && \
  mix test test/esr_web/cli_channel_test.exs
```

Expected: FAIL.

- [ ] **Step 3: Extend `dispatch("cli:actors/inspect", ...)` in `cli_channel.ex`**

In `runtime/lib/esr_web/cli_channel.ex`, add a clause BEFORE the existing `def dispatch("cli:actors/inspect", %{"arg" => actor_id} ...)` (line 63):

```elixir
def dispatch(
      "cli:actors/inspect",
      %{"arg" => actor_id, "field" => field}
    )
    when is_binary(actor_id) and is_binary(field) do
  case Esr.PeerRegistry.lookup(actor_id) do
    {:ok, _pid} ->
      snap = Esr.PeerServer.describe(actor_id)
      data = %{"actor_id" => snap.actor_id, "state" => stringify_keys(snap.state)}
      path = String.split(field, ".")

      case get_in_nested(data, path) do
        nil ->
          %{
            "data" => %{
              "error" => "field not present",
              "field" => field,
              "actor_id" => actor_id
            }
          }

        value ->
          %{
            "data" => %{
              "actor_id" => actor_id,
              "field" => field,
              "value" => value
            }
          }
      end

    :error ->
      %{"data" => %{"error" => "actor not found", "actor_id" => actor_id}}
  end
end

defp get_in_nested(map, [key]), do: Map.get(map, key) || Map.get(map, String.to_atom(key))

defp get_in_nested(map, [key | rest]) do
  case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
    nil -> nil
    nested when is_map(nested) -> get_in_nested(nested, rest)
    _ -> nil
  end
end

defp get_in_nested(_, _), do: nil
```

- [ ] **Step 4: Run — expect pass**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime && \
  mix test test/esr_web/cli_channel_test.exs
```

Expected: PASS (2 tests).

- [ ] **Step 5: Write the failing stub for scenario 03**

```bash
#!/usr/bin/env bash
# PR-7 scenario 03 — tmux attach + pane edit.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"
echo "scenario 03: stub"
exit 1
```

Run → fail.

- [ ] **Step 6: Flesh out scenario 03**

```bash
#!/usr/bin/env bash
# PR-7 scenario 03 — tmux attach + pane edit + detach + end.
# §9 user-steps 9-12. Uses cli:actors/inspect --field (extended in H).
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

load_agent_yaml
start_mock_feishu
start_esrd
register_feishu_adapter

# --- user-step 10: create session -----------------------------------
uv run --project "${_E2E_REPO_ROOT}/py" esr cmd run \
  "/new-session esr-dev tag=tmux app_id=e2e-mock"
for _ in $(seq 1 50); do
  if uv run --project "${_E2E_REPO_ROOT}/py" esr actors list 2>/dev/null \
       | grep -q "cc:tmux"; then break; fi
  sleep 0.1
done
assert_actors_list_has "cc:tmux" "user-step 10: cc:tmux peer spawned"

# Find tmux_process actor id for this session.
TMUX_ACTOR=$(uv run --project "${_E2E_REPO_ROOT}/py" esr actors list --json \
  | jq -r '.[] | select(.actor_type=="tmux_process" and (.actor_id | contains("tmux"))) | .actor_id' \
  | head -n1)
[[ -n "$TMUX_ACTOR" ]] || _fail_with_context "no tmux_process actor for cc:tmux"

# Ask runtime for state.session_name (introspection path — spec §3.4 option A).
TMUX_SESSION_NAME=$(uv run --project "${_E2E_REPO_ROOT}/py" esr actors inspect \
  "$TMUX_ACTOR" --field state.session_name)
[[ -n "$TMUX_SESSION_NAME" && "$TMUX_SESSION_NAME" =~ ^esr_cc_[0-9]+$ ]] || \
  _fail_with_context "unexpected tmux session name: '${TMUX_SESSION_NAME}'"

# --- user-step 11: send keys + capture pane --------------------------
tmux -S "${ESR_E2E_TMUX_SOCK}" send-keys -t "${TMUX_SESSION_NAME}" \
  "echo hello-tmux" Enter
sleep 0.5
assert_tmux_pane_contains "${TMUX_SESSION_NAME}" "hello-tmux"

# --- user-step 12: end session --------------------------------------
uv run --project "${_E2E_REPO_ROOT}/py" esr cmd run "/end-session tmux"
for _ in $(seq 1 50); do
  if ! uv run --project "${_E2E_REPO_ROOT}/py" esr actors list 2>/dev/null \
         | grep -q "cc:tmux"; then break; fi
  sleep 0.1
done
assert_actors_list_lacks "cc:tmux" "user-step 12: tmux peer torn down"

echo "PASS: scenario 03"
```

Note: the Python CLI `esr actors inspect <actor_id> --field state.session_name` also needs to forward the `--field` arg to `cli:actors/inspect`. If the Python CLI (under `py/src/esr_cli/`) doesn't yet pass `field`, add the passthrough in the same commit. Check with:

```bash
grep -n "actors/inspect\|actors inspect" /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/py/src/ -r
```

If the Python side builds the payload from argparse, add `--field` to the `actors inspect` subparser and include it in the payload when non-empty. (Exact file path depends on the CLI module layout; the grep above locates it in < 5 seconds.)

- [ ] **Step 7: Run**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor && \
  bash tests/e2e/scenarios/03_tmux_attach_edit.sh
```

Expected: `PASS: scenario 03`. Wall time ≤ 45 s.

- [ ] **Step 8: Commit**

```bash
git add tests/e2e/scenarios/03_tmux_attach_edit.sh \
        runtime/lib/esr_web/cli_channel.ex \
        runtime/test/esr_web/cli_channel_test.exs \
        py/src/esr_cli/  # whatever paths the --field plumbing touches
git commit -m "$(cat <<'EOF'
feat(e2e): scenario 03 + cli:actors/inspect --field (Task H)

CliChannel.dispatch accepts {arg, field} and returns the dotted path
value from the peer's describe map. Scenario 03 uses it to resolve the
live tmux session name (esr_cc_<int>) — avoids pattern-matching the
unique-integer suffix. Covers §9 user-steps 10-12.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task K1: sanitize `adapters/cc_mcp/src/esr_cc_mcp/tools.py`

**Goal:** Rewrite the 6 `Feishu` mentions to adapter-agnostic phrasing + pin the invariant with a schema-language test.

**Files:**
- Modify: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/adapters/cc_mcp/src/esr_cc_mcp/tools.py`
- Create: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/adapters/cc_mcp/tests/test_tools_schema_language.py`

**Independent of:** everything else. Can land in parallel with D1/D2/J1.

- [ ] **Step 1: Write failing test — no case-insensitive `feishu` in tool descriptions**

Create `adapters/cc_mcp/tests/test_tools_schema_language.py`:

```python
"""K1 — tool schema descriptions must be adapter-agnostic (spec §13 item 4).

Runs as part of the adapters/cc_mcp test suite; fails the build if a
"Feishu" mention creeps back in.
"""
from __future__ import annotations

import re

from esr_cc_mcp.tools import list_tool_schemas


def test_no_feishu_in_tool_descriptions() -> None:
    tools = list_tool_schemas(role="diagnostic")
    pat = re.compile(r"feishu", re.IGNORECASE)
    offenders: list[str] = []
    for t in tools:
        if pat.search(t.description or ""):
            offenders.append(f"{t.name}.description: {t.description!r}")
        for prop_name, prop in (t.inputSchema.get("properties") or {}).items():
            desc = prop.get("description") or ""
            if pat.search(desc):
                offenders.append(f"{t.name}.{prop_name}.description: {desc!r}")
    assert offenders == [], "K1: sanitize these:\n  " + "\n  ".join(offenders)
```

- [ ] **Step 2: Run — expect fail (6 hits)**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor && \
  uv run --project py pytest adapters/cc_mcp/tests/test_tools_schema_language.py -v
```

Expected: FAIL with 6 offender entries.

- [ ] **Step 3: Rewrite `tools.py`**

Replace the file content:

```python
"""MCP tool schemas for esr-channel (spec §3.1 / §5.3).

Three user-facing tools + one diagnostic tool gated on the workspace
role. Schema shapes match cc-openclaw's openclaw-channel reply / react /
send_file tools (API-compatible per spec §1.1 point 1) so switching CC
from one channel to the other is drop-in.

Descriptions are channel-agnostic: the CC chain's abstraction boundary
(spec §2) forbids this module from naming any specific channel adapter.
"""
from __future__ import annotations

from mcp.types import Tool

_REPLY = Tool(
    name="reply",
    description=(
        "Send a message to the user's chat channel. The user reads the "
        "channel, not this session — anything you want them to see must go "
        "through this tool. chat_id is from the inbound <channel> tag "
        "(opaque token scoped to the active channel). Pass edit_message_id "
        "to edit an existing message in-place instead of sending a new one "
        "(covers update_title semantics)."
    ),
    inputSchema={
        "type": "object",
        "properties": {
            "chat_id": {
                "type": "string",
                "description": "Channel chat ID (opaque token scoped to the active channel)",
            },
            "text": {"type": "string", "description": "Message text"},
            "edit_message_id": {
                "type": "string",
                "description": "Optional message_id to edit in-place",
            },
        },
        "required": ["chat_id", "text"],
    },
)

_REACT = Tool(
    name="react",
    description="Add an emoji reaction to a channel message",
    inputSchema={
        "type": "object",
        "properties": {
            "message_id": {
                "type": "string",
                "description": "Message ID (opaque token scoped to the active channel)",
            },
            "emoji_type": {
                "type": "string",
                "description": (
                    "Emoji code (channel-specific; e.g. THUMBSUP, DONE, OK "
                    "for common chat channels)"
                ),
            },
        },
        "required": ["message_id", "emoji_type"],
    },
)

_SEND_FILE = Tool(
    name="send_file",
    description=(
        "Send a file to the user's chat channel. Uploads the local file "
        "and sends it as a file message."
    ),
    inputSchema={
        "type": "object",
        "properties": {
            "chat_id": {
                "type": "string",
                "description": "Channel chat ID (opaque token scoped to the active channel)",
            },
            "file_path": {"type": "string", "description": "Absolute path to local file"},
        },
        "required": ["chat_id", "file_path"],
    },
)

_ECHO = Tool(
    name="_echo",
    description=(
        "DIAGNOSTIC ONLY. Echo a nonce back as a reply to ESR_SELF_CHAT_ID. "
        "Gated on workspace role='diagnostic'. Used by final_gate --live v2 "
        "to make L2/L6 deterministic without LLM judgement."
    ),
    inputSchema={
        "type": "object",
        "properties": {"nonce": {"type": "string"}},
        "required": ["nonce"],
    },
)


def list_tool_schemas(*, role: str) -> list[Tool]:
    """Return the tool list CC sees — `_echo` only when role=diagnostic."""
    tools = [_REPLY, _REACT, _SEND_FILE]
    if role == "diagnostic":
        tools.append(_ECHO)
    return tools
```

- [ ] **Step 4: Run — expect pass**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor && \
  uv run --project py pytest adapters/cc_mcp/tests/test_tools_schema_language.py -v
```

Expected: PASS.

- [ ] **Step 5: Run the case-insensitive grep from spec §13 item 4 — scope: adapters/cc_mcp/src only — expect zero**

```bash
grep -irn 'feishu' \
  /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/adapters/cc_mcp/src/
```

Expected: 0 matches.

- [ ] **Step 6: Run the full cc_mcp test suite to catch regressions**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor && \
  uv run --project py pytest adapters/cc_mcp/ -v
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add adapters/cc_mcp/src/esr_cc_mcp/tools.py \
        adapters/cc_mcp/tests/test_tools_schema_language.py
git commit -m "$(cat <<'EOF'
refactor(cc_mcp): sanitize tool descriptions — adapter-agnostic (Task K1)

Rewrites 6 "Feishu" mentions in tools.py to channel-agnostic phrasing.
Pins the invariant with a schema-language regression test: grep -i
'feishu' across every tool.description and property description must
return zero. Spec §2 architectural invariant.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task K2: sanitize CC peer module docstrings

**Goal:** Drop `FeishuChatProxy` literals from `cc_proxy.ex:3` and `cc_process.ex:7`.

**Files:**
- Modify: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr/peers/cc_proxy.ex`
- Modify: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr/peers/cc_process.ex`

**Independent of:** everything.

- [ ] **Step 1: Run the case-insensitive grep — confirm baseline**

```bash
grep -irn 'feishu' \
  /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr/peers/cc_proxy.ex \
  /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr/peers/cc_process.ex
```

Expected: 2 hits (one each).

- [ ] **Step 2: Rewrite `cc_proxy.ex` moduledoc line 3**

Replace:

```
Stateless Peer.Proxy between FeishuChatProxy (upstream) and CCProcess
```

with:

```
Stateless Peer.Proxy between the upstream chat proxy and CCProcess
```

- [ ] **Step 3: Rewrite `cc_process.ex` moduledoc line 7**

Replace:

```
  `TmuxProcess` neighbor (`:send_input`) or upward replies to
  `FeishuChatProxy` via `CCProxy` (`:reply`).
```

with:

```
  `TmuxProcess` neighbor (`:send_input`) or upward replies to the
  upstream chat proxy via `CCProxy` (`:reply`).
```

- [ ] **Step 4: Rerun the grep — expect zero**

```bash
grep -irn 'feishu' \
  /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr/peers/cc_proxy.ex \
  /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr/peers/cc_process.ex
```

Expected: 0 matches.

- [ ] **Step 5: Run mix test to confirm docstring changes don't break anything**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime && \
  mix test test/esr/peers/cc_proxy_test.exs test/esr/peers/cc_process_test.exs
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add runtime/lib/esr/peers/cc_proxy.ex runtime/lib/esr/peers/cc_process.ex
git commit -m "$(cat <<'EOF'
refactor(peers): drop FeishuChatProxy literals from CC peer docs (Task K2)

Replace hardcoded FeishuChatProxy references in cc_proxy.ex and
cc_process.ex moduledocs with "upstream chat proxy". Matches K1 in
purging channel-specific references from the CC-reachable codebase.
Spec §2 grep-proof acceptance criterion (§13 item 4).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task I: Makefile targets + `ESR_E2E_CI` mode

**Goal:** Inline Makefile targets + CI mode teardown. Depends on F, G, H (the scripts exist and pass individually).

**Files:**
- Modify: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/Makefile`
- Modify: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/tests/e2e/scenarios/common.sh` (extend `_e2e_teardown` with CI-mode branch)

- [ ] **Step 1: Write a failing Makefile target dry-run**

Attempt:

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor && \
  make -n e2e
```

Expected: FAIL with `make: *** No rule to make target 'e2e'.`

- [ ] **Step 2: Append e2e targets to the Makefile**

Edit `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/Makefile` — append to the existing `.PHONY` list and add the recipes:

Replace the first line:

```makefile
.PHONY: test test-py test-ex lint fmt run-runtime clean
```

with:

```makefile
.PHONY: test test-py test-ex lint fmt run-runtime clean e2e e2e-ci e2e-01 e2e-02 e2e-03
```

Append to the end of the file:

```makefile

# --- PR-7 end-to-end scenarios ---------------------------------------
# Run all three scenarios serially. Wall-time budget: <5 min total.
# Hard timeout wrapper — prevents a hung esrd from holding GitHub Actions.
e2e: e2e-01 e2e-02 e2e-03

e2e-01:
	timeout 300 bash tests/e2e/scenarios/01_single_user_create_and_end.sh

e2e-02:
	timeout 300 bash tests/e2e/scenarios/02_two_users_concurrent.sh

e2e-03:
	timeout 300 bash tests/e2e/scenarios/03_tmux_attach_edit.sh

# CI variant: absolute cleanup (§7.2). Same scripts, different env.
e2e-ci:
	ESR_E2E_CI=1 $(MAKE) e2e
```

- [ ] **Step 3: Extend `_e2e_teardown` in common.sh to honour ESR_E2E_CI**

Edit `tests/e2e/scenarios/common.sh` — replace the existing `_e2e_teardown` function with:

```bash
_e2e_teardown() {
  # Idempotent teardown — safe to run twice.
  [[ -f "/tmp/mock-feishu-${ESR_E2E_RUN_ID}.pid" ]] && {
    kill -9 "$(cat /tmp/mock-feishu-${ESR_E2E_RUN_ID}.pid)" 2>/dev/null || true
    rm -f "/tmp/mock-feishu-${ESR_E2E_RUN_ID}.pid"
  }
  rm -f /tmp/.sidecar.pid 2>/dev/null || true
  rm -f /tmp/esr-worker-*.pid 2>/dev/null || true
  if [[ -S "${ESR_E2E_TMUX_SOCK}" ]]; then
    tmux -S "${ESR_E2E_TMUX_SOCK}" kill-server 2>/dev/null || true
  fi
  rm -rf "${ESRD_HOME}" "${ESR_E2E_BARRIER_DIR}" \
         "/tmp/mock-feishu-files-${MOCK_FEISHU_PORT}" 2>/dev/null || true

  # Best-effort esrd stop.
  ( cd "${_E2E_REPO_ROOT}" && \
    bash scripts/esrd.sh stop --instance="${ESRD_INSTANCE}" 2>/dev/null ) || true

  # CI-only absolute cleanup (§7.2).
  if [[ "${ESR_E2E_CI:-0}" == "1" ]]; then
    rm -rf /tmp/esrd-e2e-* /tmp/esr-e2e-* /tmp/mock-feishu-files-* 2>/dev/null || true
    pkill -f "mock_feishu.py --port 82" 2>/dev/null || true
    pkill -f "erlexec.*esr" 2>/dev/null || true
    tmux kill-server 2>/dev/null || true
  fi
}
```

- [ ] **Step 4: Run `make e2e` against a fresh checkout**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor && \
  make clean && make e2e
```

Expected: three PASS lines; total wall time ≤ 3 min; exit 0.

- [ ] **Step 5: Run `make e2e` a second time immediately (idempotency check — spec §13 item 2)**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor && \
  make e2e
```

Expected: PASS again. Confirms cleanup is run-scoped.

- [ ] **Step 6: Exercise CI mode locally**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor && \
  make e2e-ci
```

Expected: PASS. Confirms the absolute-cleanup branch doesn't break anything on a dev host (nukes only artefacts our scripts could have created).

- [ ] **Step 7: Commit**

```bash
git add Makefile tests/e2e/scenarios/common.sh
git commit -m "$(cat <<'EOF'
build: make e2e / e2e-ci targets + CI-mode cleanup (Task I)

Inlines the three scenario recipes + CI variant into the top-level
Makefile (no fragment include — spec §11.1). common.sh gains the
ESR_E2E_CI branch that performs absolute cleanup per §7.2 (pkill on
mock_feishu + erlexec + tmux kill-server). Each recipe wraps its
scenario in `timeout 300` so a hung esrd can't hold CI.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task J: Documentation cross-refs

**Goal:** A small README under `tests/e2e/` explaining what's there, how to run, and where to look when something fails. Optional touch-up to top-level docs if discoverable paths exist.

**Files:**
- Create: `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/tests/e2e/README.md`

- [ ] **Step 1: Create the README**

```markdown
# PR-7 end-to-end scenarios

Three bash scripts + shared preamble that exercise the Feishu → CC
business topology against a running `esrd` + `scripts/mock_feishu.py`.

## Running

```bash
make e2e       # all three scenarios, dev-mode cleanup
make e2e-01    # just scenario 01 (single user)
make e2e-02    # just scenario 02 (two users concurrent)
make e2e-03    # just scenario 03 (tmux attach/edit)
make e2e-ci    # CI-mode: absolute cleanup after (pkill + tmux kill-server)
```

Each recipe has a `timeout 300` wrapper so a hung esrd cannot hold CI.

## Structure

| File | Purpose |
|------|---------|
| `scenarios/common.sh` | Env bootstrap, assertion helpers, barrier primitives, trap-based teardown. All three scripts source it. |
| `scenarios/01_single_user_create_and_end.sh` | §9 user-steps 1-6 + 12. Create session, plain message, react, send_file, second message, end. |
| `scenarios/02_two_users_concurrent.sh` | §9 user-steps 7-8. Two bash subshells with barrier-sync'd probes; asserts cross-session isolation. |
| `scenarios/03_tmux_attach_edit.sh` | §9 user-steps 9-12. Resolve live tmux session name via `esr actors inspect --field state.session_name`; send-keys; capture-pane. |
| `fixtures/probe_file.txt` | 1 KB probe for `send_file`. |
| `scenarios/_common_selftest.sh` | Self-test for `common.sh`; run in CI before the real scenarios. |

## Design spec

`/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/docs/superpowers/specs/2026-04-23-pr7-e2e-feishu-to-cc-design.md`

## Wire contracts

`/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/docs/notes/pr7-wire-contracts.md`

## Debugging a failure

1. `_on_err` trap prints the failing line + `ESR_E2E_RUN_ID` + tail of
   `/tmp/mock-feishu-${ESR_E2E_RUN_ID}.log`.
2. Set `ESR_E2E_RUN_ID` manually to preserve artefacts:
   `ESR_E2E_RUN_ID=debug-$$ bash tests/e2e/scenarios/01_single_user_create_and_end.sh`.
   The trap still teardowns under the same run_id at the end — comment
   out `_e2e_teardown || true` in `_on_exit` locally if you need to
   poke at `${ESRD_HOME}` or `${ESR_E2E_BARRIER_DIR}` after a failure.
3. Known-slow cold start: mock_feishu takes ~2 s, esrd ~15 s. Scripts
   have a 5 s readiness probe on the mock.
```

- [ ] **Step 2: Commit**

```bash
git add tests/e2e/README.md
git commit -m "$(cat <<'EOF'
docs(e2e): README cross-refs for PR-7 scenarios (Task J)

Points to the design spec, wire-contracts doc, and common.sh. Lists
each script's §9 user-step coverage + debug tips.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

### 1. Spec coverage

| Spec section | Covered by |
|--------------|------------|
| §1 Overview / scope | Tasks F, G, H (the three scripts) + I (`make e2e`) |
| §2 Architectural invariant (adapter-agnostic CC) | D1 + D2 (plumbing + emit); K1 + K2 (doc/string sanitization) |
| §3.1 `common.sh` | Task A |
| §3.2 scenario 01 | Task F |
| §3.3 scenario 02 | Task G |
| §3.4 scenario 03 + introspection path | Task H |
| §3.5 tmux_socket env plumbing | Task J1 |
| §4.1 `send_file` directive in adapter | Task C |
| §4.2 unhardcode adapter name | D1 + D2 |
| §5.1 `/reactions` endpoint + msg_id fix | Task B + D2 |
| §5.2 `/files` + `/sent_files` | Task B |
| §6 α wire shape | D2 (Elixir emit) + C (Python decode) |
| §7.1 default teardown | Task A (trap) + I (common.sh fleshed out) |
| §7.2 CI teardown | Task I |
| §8 assertion set | Task A |
| §9 coverage matrix | F/G/H |
| §10 `simple.yaml` reuse | Task A (`load_agent_yaml`) |
| §11 Makefile | Task I |
| §12 CC tool → directive mapping | D2 + C |
| §13 acceptance criteria | Entire plan — grep checks in K1 (step 5), I (step 5 idempotency) |
| §13 item 4 grep (case-insensitive) | K1 step 5 + K2 step 4 |
| §13 items 5-6 unit tests | C (steps 3-4 and 7-8) |
| §14 deferred items | Logged in spec; nothing to do in plan |
| §15 task list (14 tasks) | All covered; IDs preserved |

No spec gaps.

### 2. Placeholder scan

Searched for "TBD", "TODO", "implement later", "fill in details", "appropriate error handling", "handle edge cases", "Similar to Task N" — zero matches. Every step has explicit code or exact commands.

**One exception:** Task H Step 6 mentions "the Python CLI … exact file path depends on the CLI module layout; the grep above locates it" — this is an intentional deferment of a < 5-second grep rather than a placeholder for unspecified work. The grep command is given; the executing agent runs it and gets a definitive answer.

### 3. Type consistency

- `channel_adapter` is string-keyed in the thread-state map (`"channel_adapter"`) throughout D1 → D2 — verified.
- Atom-keyed in `params` (`:channel_adapter`) within Elixir-only plumbing (`stamp_channel_adapter_for_test`, `build_ctx`, `ctx` map) — verified.
- `session_channel_adapter/1` reads the string key from the struct's `:state` map field — matches D1 seeding.
- `msg_id` (adapter side) vs `message_id` (MCP tool input) — explicit in D2 Step 3b comment.
- `sha256` is lowercase hex (`Base.encode16(case: :lower)`) on both Elixir and Python sides (Elixir uses explicit case option; Python uses `hashlib.sha256().hexdigest()` which is lowercase by default).
- `Application.get_env(:esr, :tmux_socket_override)` — same atom key in J1 Steps 3, 4, and 7.

No inconsistencies detected.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-04-23-pr7-e2e-feishu-to-cc.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in the current session with checkpoints per the executing-plans skill.

Per the user's standing memory rule (`feedback_subagent_review_plans`), a separate `code-reviewer` subagent should review this plan before execution begins.
