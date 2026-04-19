#!/usr/bin/env bash
# kill_scenario_workers.sh — Phase 8e teardown helper.
#
# Counterpart to spawn_scenario_workers.sh. Reads every
# /tmp/esr-worker-*.pid pidfile, sends SIGTERM, then removes the pidfile.
# Best-effort; errors are non-fatal (teardown per spec must not abort).
set -u

for pf in /tmp/esr-worker-*.pid; do
  [ -f "$pf" ] || continue
  pid=$(cat "$pf" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
  fi
  rm -f "$pf"
done

# Give TERM a chance; then SIGKILL anything still alive.
sleep 1
pgrep -f 'esr\.ipc\.(adapter_runner|handler_worker)' | while read -r pid; do
  kill -9 "$pid" 2>/dev/null || true
done

echo "scenario workers cleaned up"
