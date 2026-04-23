#!/usr/bin/env bash
# spawn_scenario_workers.sh — Phase 8e setup helper.
#
# Launches the fire-and-forget Python adapter/handler worker subprocesses
# a scenario needs *joined to their channels* before Topology.Instantiator
# broadcasts init_directive envelopes. Without a joined peer, the broadcast
# fans out to nobody and the 30s init_directive timeout fires → step A
# times out.
#
# Writes a pidfile per launched worker at /tmp/esr-worker-<slug>.pid so
# teardown can kill them.
#
# Usage:
#   scripts/spawn_scenario_workers.sh <handler_hub_url> <adapter_hub_url> \
#       <thread_id> [<thread_id> ...]
#
# handler_hub_url and adapter_hub_url are the same WS URL — the script
# interpolates the path — but we pass them separately to make the call
# sites unambiguous. Example:
#   scripts/spawn_scenario_workers.sh \
#       ws://127.0.0.1:4001/handler_hub/socket/websocket?vsn=2.0.0 \
#       ws://127.0.0.1:4001/adapter_hub/socket/websocket?vsn=2.0.0 \
#       alpha beta gamma
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "usage: $0 <handler_hub_url> <adapter_hub_url> <thread_id> [<thread_id> ...]" >&2
  exit 2
fi

HANDLER_URL="$1"
ADAPTER_URL="$2"
shift 2

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

# Ensure cc_tmux config is non-empty — AdapterConfig does not accept an empty
# dict for some factories but the mock flow doesn't actually read fields.
CC_TMUX_CONFIG='{"start_cmd":"./e2e-cc.sh"}'

# Unique feishu-shared instance for the e2e scenario.
FEISHU_CONFIG='{"app_id":"mock_app","app_secret":"mock_secret","base_url":"http://127.0.0.1:8101"}'

# Track ONLY the pidfiles this script creates — any leftover
# /tmp/esr-worker-*.pid from prior unit-test runs of WorkerSupervisor
# must not contaminate our liveness check.
OUR_PIDFILES=()

spawn_bg() {
  local slug="$1" log="$2"
  shift 2
  local pidfile="/tmp/esr-worker-${slug}.pid"
  # Run detached from this script's stdin/out so subprocess.run in the
  # scenario runner doesn't hang waiting on FDs.
  ( "$@" >"$log" 2>&1 ) &
  local pid=$!
  echo "$pid" >"$pidfile"
  OUR_PIDFILES+=("$pidfile")
  echo "spawned ${slug} pid=${pid} log=${log}"
}

# --- Adapter workers -------------------------------------------------
# cc_tmux adapter instance per thread_id.
for t in "$@"; do
  instance="tmux:${t}"
  slug="adapter-cc_tmux-${t}"
  log="/tmp/esr-worker-${slug}.log"
  # PR-4b: cc_tmux speaks via cc_adapter_runner (dedicated sidecar).
  spawn_bg "$slug" "$log" \
    uv run --project py python -m cc_adapter_runner \
      --adapter cc_tmux \
      --instance-id "$instance" \
      --url "$ADAPTER_URL" \
      --config-json "$CC_TMUX_CONFIG"
done

# feishu adapter — shared across all threads. PR-4b: feishu speaks via
# feishu_adapter_runner (dedicated sidecar).
spawn_bg "adapter-feishu-shared" "/tmp/esr-worker-adapter-feishu-shared.log" \
  uv run --project py python -m feishu_adapter_runner \
    --adapter feishu \
    --instance-id "shared" \
    --url "$ADAPTER_URL" \
    --config-json "$FEISHU_CONFIG"

# --- Handler workers -------------------------------------------------
# feishu_thread.on_msg — one worker per thread_id.
for t in "$@"; do
  slug="handler-feishu_thread-${t}"
  log="/tmp/esr-worker-${slug}.log"
  spawn_bg "$slug" "$log" \
    uv run --project py python -m esr.ipc.handler_worker \
      --module "feishu_thread.on_msg" \
      --worker-id "w-${t}" \
      --url "$HANDLER_URL"
done

# cc_session.on_msg — one worker per thread_id.
for t in "$@"; do
  slug="handler-cc_session-${t}"
  log="/tmp/esr-worker-${slug}.log"
  spawn_bg "$slug" "$log" \
    uv run --project py python -m esr.ipc.handler_worker \
      --module "cc_session.on_msg" \
      --worker-id "w-${t}" \
      --url "$HANDLER_URL"
done

# tmux_proxy.on_msg — one worker per thread_id.
for t in "$@"; do
  slug="handler-tmux_proxy-${t}"
  log="/tmp/esr-worker-${slug}.log"
  spawn_bg "$slug" "$log" \
    uv run --project py python -m esr.ipc.handler_worker \
      --module "tmux_proxy.on_msg" \
      --worker-id "w-${t}" \
      --url "$HANDLER_URL"
done

# Give the workers a moment to connect + join.
sleep 2

# Sanity-check only the pidfiles we just wrote — leftover /tmp pidfiles
# from earlier WorkerSupervisor unit tests (short-lived noop processes)
# must not cause this setup step to fail.
fail=0
for pf in "${OUR_PIDFILES[@]}"; do
  pid=$(cat "$pf")
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "worker pidfile $pf is stale (pid=$pid not alive)" >&2
    fail=1
  fi
done
if [ "$fail" -ne 0 ]; then
  echo "one or more workers failed to start; check /tmp/esr-worker-*.log" >&2
  exit 1
fi

echo "all scenario workers up"
