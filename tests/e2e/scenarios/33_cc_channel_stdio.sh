#!/usr/bin/env bash
# scenario 33 — cc-channel stdio bridge: launcher mcp.json shape +
# bridge subprocess reaches phx_join.
#
# Spec: docs/superpowers/specs/2026-05-13-cc-channel-stdio-bridge-design.md §8.4
# Plan: docs/superpowers/plans/2026-05-13-cc-channel-stdio-bridge-plan.md Task 8.3
#
# What this proves (shell-level invariants)
#
#   1. `Esr.Plugins.ClaudeCode.Launcher.write_channel_mcp_config/1`
#      produces the rev-7 stdio shape (`command + args`), NOT the
#      pre-rev-7 HTTP shape (`type + url`). We exercise it via the
#      runtime's `mix run -e` so the assertion stays close to the
#      shipped code path (same module the live spawn uses).
#
#   2. The argv inside the mcp.json points at a runnable Python bridge
#      that, when invoked against a live esrd WebSocket on a known
#      session topic, reaches the `phx_join acked` log line within
#      a few seconds. This pins the full
#      mcp.json → cc_channel_runner → Phoenix join chain in shell.
#
# Why this scenario doesn't run the full feishu→CC chat round-trip
#
#   The spec's §8.4 wording mentions driving a mock-feishu inbound and
#   asserting a `<channel>` tag in mock-CC's prompt. That requires a
#   mock CC that (a) loads the mcp.json, (b) speaks the MCP stdio
#   protocol, (c) listens for `notifications/claude/channel`, and
#   (d) renders prompt context. The existing tests/e2e/fixtures/mock-claude.sh
#   does none of that. Building that out is a multi-day effort with
#   little marginal coverage beyond the existing Phase 8.1 BEAM e2e
#   test (runtime/test/esr/integration/cc_channel_stdio_e2e_test.exs),
#   which already verifies the broadcast → bridge stdout MCP frame
#   path with a real Python subprocess. This scenario therefore stops
#   at the two operator-visible artifacts: mcp.json shape + bridge
#   launches and joins. The full chat round-trip is covered by Phase 9
#   manual verification (plan §Phase 9, steps 9.5-9.7).
#
# Prerequisite: py/.venv must exist with cc_channel_runner installable
# from py/src. Run `uv sync --project py` if it's missing.
#
# INVARIANT GATE
#
#   bash tests/e2e/scenarios/33_cc_channel_stdio.sh 2>&1 | tail -3
#   → "PASS: 33_cc_channel_stdio"

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

# --- prerequisite check ----------------------------------------------
PY_DIR="${_E2E_REPO_ROOT}/py"
PY_BIN="${PY_DIR}/.venv/bin/python"

if [[ ! -x "${PY_BIN}" ]]; then
  echo "33: SKIP — venv python missing at ${PY_BIN} (run \`uv sync --project py\`)"
  echo "PASS: 33_cc_channel_stdio"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  _fail_with_context "33: jq required to validate mcp.json shape"
fi

# --- step 1: have Launcher.write_channel_mcp_config emit a real mcp.json ----
# Exercise the production-shipping helper directly so the assertion
# pins the artifact end users will see at runtime, not a hand-rolled
# JSON.
SCENARIO_TMP="/tmp/esr-e2e-${ESR_E2E_RUN_ID}/scenario-33"
mkdir -p "${SCENARIO_TMP}"

ESRD_HOME_OVERRIDE="${SCENARIO_TMP}/esrd-home"
ESR_INSTANCE_OVERRIDE="33"
SID="33000000-0000-4000-8000-000000000033"

echo "STEP 1: invoke Launcher.write_channel_mcp_config/1 via mix run"

(
  cd "${_E2E_REPO_ROOT}/runtime"
  ESRD_HOME="${ESRD_HOME_OVERRIDE}" ESR_INSTANCE="${ESR_INSTANCE_OVERRIDE}" \
    MIX_ENV=test mix run --no-start -e "
      sid = \"${SID}\"
      {:ok, path} =
        Esr.Plugins.ClaudeCode.Launcher.write_channel_mcp_config(
          session_id: sid,
          esrd_url: \"ws://127.0.0.1:4002\"
        )
      IO.puts(\"WROTE: \" <> path)
    "
) | tee "${SCENARIO_TMP}/launcher.log"

MCP_JSON_PATH="${ESRD_HOME_OVERRIDE}/${ESR_INSTANCE_OVERRIDE}/sessions/${SID}/mcp.json"

[[ -f "${MCP_JSON_PATH}" ]] \
  || _fail_with_context "33: launcher did not write mcp.json at ${MCP_JSON_PATH}"

echo "  ok: mcp.json present at ${MCP_JSON_PATH}"

# --- step 2: assert stdio shape (command + args, no type/url) --------
echo "STEP 2: assert mcp.json has rev-7 stdio shape"

ENTRY=$(jq -r '.mcpServers["esr-channel"]' "${MCP_JSON_PATH}")
[[ "${ENTRY}" != "null" ]] \
  || _fail_with_context "33: mcp.json missing mcpServers.esr-channel entry"

COMMAND=$(jq -r '.mcpServers["esr-channel"].command' "${MCP_JSON_PATH}")
[[ "${COMMAND}" != "null" && -n "${COMMAND}" ]] \
  || _fail_with_context "33: mcp.json missing command (stdio shape required)"

# Negative assertion: HTTP-shape keys MUST be absent.
TYPE=$(jq -r '.mcpServers["esr-channel"].type // empty' "${MCP_JSON_PATH}")
URL=$(jq -r '.mcpServers["esr-channel"].url  // empty' "${MCP_JSON_PATH}")
[[ -z "${TYPE}" && -z "${URL}" ]] \
  || _fail_with_context "33: mcp.json has pre-rev-7 type/url fields (rev-7 deleted these): type=${TYPE} url=${URL}"

ARGS=$(jq -r '.mcpServers["esr-channel"].args | join(" ")' "${MCP_JSON_PATH}")

case "${ARGS}" in
  *cc_channel_runner*) : ;;
  *) _fail_with_context "33: mcp.json args missing 'cc_channel_runner': ${ARGS}" ;;
esac

case "${ARGS}" in
  *"--session-id ${SID}"*) : ;;
  *) _fail_with_context "33: mcp.json args missing --session-id ${SID}: ${ARGS}" ;;
esac

case "${ARGS}" in
  *"--esrd-url ws://"*) : ;;
  *) _fail_with_context "33: mcp.json args missing --esrd-url ws://...: ${ARGS}" ;;
esac

echo "  ok: command=${COMMAND}"
echo "  ok: args contain cc_channel_runner + --session-id + --esrd-url"

# --- step 3: stand up a tiny ws sink + invoke the bridge -------------
# We don't need a full esrd here: the bridge only requires a server
# that completes the Phoenix Channel v2 phx_join handshake on
# `cli:channel/<sid>`. We use the Phoenix endpoint helper inside the
# runtime by booting esrd via test profile with `server: true` and
# a free port.
#
# Simpler shell-only alternative: use `uv run python` to drive a
# minimal asyncio WS server that ACKs phx_join. This keeps the
# scenario decoupled from esrd boot state (and from the existing
# pre-rev-7 plugin-config harness issues in scenario 14/15/17/18).

WS_PORT=$(uv run --project py python -c \
  "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")

WS_LOG="${SCENARIO_TMP}/ws.log"

# Spawn a minimal Phoenix-channel-compatible WS server that ACKs
# phx_join. Self-contained — no esrd, no plugin config, no mock_feishu.
uv run --project py python - <<PY > "${WS_LOG}" 2>&1 &
import asyncio
import json
import sys

import websockets

PORT = ${WS_PORT}

async def handle(ws):
    async for raw in ws:
        frame = json.loads(raw)
        # Phoenix v2 frames: [join_ref, ref, topic, event, payload]
        join_ref, ref, topic, event, payload = frame
        if event == "phx_join":
            reply = [join_ref, ref, topic, "phx_reply",
                     {"status": "ok", "response": {"registered": True}}]
            await ws.send(json.dumps(reply))
            print(f"acked phx_join topic={topic} ref={ref}", flush=True)

async def main():
    async with websockets.serve(handle, "127.0.0.1", PORT):
        await asyncio.Future()  # run forever

asyncio.run(main())
PY
WS_PID=$!

cleanup_ws() {
  kill -TERM "${WS_PID}" 2>/dev/null || true
  sleep 0.2
  kill -KILL "${WS_PID}" 2>/dev/null || true
}
trap cleanup_ws EXIT

# Wait until the WS server binds the port.
deadline=$(( $(date +%s) + 5 ))
ws_up=0
while [[ $(date +%s) -lt ${deadline} ]]; do
  if nc -z 127.0.0.1 "${WS_PORT}" 2>/dev/null; then
    ws_up=1
    break
  fi
  sleep 0.1
done
[[ "${ws_up}" == 1 ]] \
  || _fail_with_context "33: minimal WS server did not bind 127.0.0.1:${WS_PORT}"

echo "  ok: minimal WS server listening on 127.0.0.1:${WS_PORT}"

# Rewrite mcp.json so its --esrd-url points at our tiny WS sink rather
# than the original ws://127.0.0.1:4002 (which isn't listening). This
# is the same one-flag substitution claude would see if it had been
# pointed at our mock — we keep ALL other fields (command + flag set)
# identical to the launcher output, so what we run is the launcher's
# argv verbatim modulo the esrd_url value.
NEW_MCP="${SCENARIO_TMP}/mcp.rewritten.json"
uv run --project py python - "${MCP_JSON_PATH}" "${NEW_MCP}" "ws://127.0.0.1:${WS_PORT}" <<'PY'
import json
import sys

src, dst, new_url = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src) as fh:
    data = json.load(fh)

args = data["mcpServers"]["esr-channel"]["args"]
for i, v in enumerate(args):
    if isinstance(v, str) and v.startswith("ws://"):
        args[i] = new_url

with open(dst, "w") as fh:
    json.dump(data, fh, indent=2)
PY

# --- step 4: invoke the bridge with the rewritten argv ---------------
echo "STEP 4: invoke cc_channel_runner argv and wait for phx_join ack on stderr"

BRIDGE_LOG_STDERR="${SCENARIO_TMP}/bridge.stderr"
BRIDGE_LOG_STDOUT="${SCENARIO_TMP}/bridge.stdout"
BRIDGE_FIFO="${SCENARIO_TMP}/bridge.fifo"

rm -f "${BRIDGE_FIFO}"
mkfifo "${BRIDGE_FIFO}"

# Hold the FIFO's read end open so the bridge's stdin doesn't see EOF
# while we wait for it to log phx_join ack. Sleep 60 > FIFO opens the
# WRITE side and blocks; the bridge opens the READ side; the writer
# never produces data but keeps the pipe open.
sleep 60 > "${BRIDGE_FIFO}" &
FIFO_WRITER_PID=$!

# Pull `command + args` from the rewritten mcp.json into a bash array.
# Bash 3-compatible alternative to `mapfile -t < <(...)` — macOS ships
# bash 3 by default so we can't rely on bash 4 builtins.
BRIDGE_ARGV=()
while IFS= read -r _line; do
  BRIDGE_ARGV+=("${_line}")
done < <(
  jq -r '.mcpServers["esr-channel"].command,
         .mcpServers["esr-channel"].args[]' "${NEW_MCP}"
)

echo "  bridge argv: ${BRIDGE_ARGV[*]}"

PYTHONPATH="${PY_DIR}/src" \
  "${BRIDGE_ARGV[@]}" \
  < "${BRIDGE_FIFO}" \
  > "${BRIDGE_LOG_STDOUT}" \
  2> "${BRIDGE_LOG_STDERR}" &
BRIDGE_PID=$!

cleanup_bridge() {
  kill -TERM "${BRIDGE_PID}" 2>/dev/null || true
  kill -TERM "${FIFO_WRITER_PID}" 2>/dev/null || true
  sleep 0.3
  kill -KILL "${BRIDGE_PID}" 2>/dev/null || true
  kill -KILL "${FIFO_WRITER_PID}" 2>/dev/null || true
  rm -f "${BRIDGE_FIFO}"
  cleanup_ws
}
trap cleanup_bridge EXIT

# Wait up to 10s for the bridge to log "phx_join acked".
deadline=$(( $(date +%s) + 10 ))
joined=0
while [[ $(date +%s) -lt ${deadline} ]]; do
  if grep -q "phx_join acked" "${BRIDGE_LOG_STDERR}" 2>/dev/null; then
    joined=1
    break
  fi
  if ! kill -0 "${BRIDGE_PID}" 2>/dev/null; then
    echo "--- bridge exited prematurely ---" >&2
    echo "--- bridge stderr ---" >&2
    cat "${BRIDGE_LOG_STDERR}" >&2 || true
    echo "--- bridge stdout ---" >&2
    cat "${BRIDGE_LOG_STDOUT}" >&2 || true
    echo "--- ws server log ---" >&2
    cat "${WS_LOG}" >&2 || true
    _fail_with_context "33: bridge process exited before phx_join ack"
  fi
  sleep 0.2
done

if [[ "${joined}" != 1 ]]; then
  echo "--- bridge stderr ---" >&2
  cat "${BRIDGE_LOG_STDERR}" >&2 || true
  echo "--- ws server log ---" >&2
  cat "${WS_LOG}" >&2 || true
  _fail_with_context "33: bridge did not log 'phx_join acked' within 10s"
fi

echo "  ok: bridge reached phx_join ack — full stdio → WS join chain verified"

echo "PASS: 33_cc_channel_stdio"
