#!/usr/bin/env bash
# scripts/esrd.sh — per-instance runtime daemon manager (Phase 8b).
#
# Usage:
#   scripts/esrd.sh start  --instance=<name>
#   scripts/esrd.sh stop   --instance=<name>
#   scripts/esrd.sh status --instance=<name>
#
# State layout:
#   $ESRD_HOME/<instance>/
#     esrd.pid           — PID of the running Phoenix server
#     logs/stdout.log    — combined stdout/stderr
#
# ESRD_HOME defaults to ~/.esrd. For tests, export ESRD_CMD_OVERRIDE to
# substitute a trivial command (e.g. "sleep 60") instead of actually
# running `mix phx.server`.
set -u

ESRD_HOME="${ESRD_HOME:-$HOME/.esrd}"

fatal() { echo "esrd: $*" >&2; exit 1; }

parse_instance() {
  instance=""
  for arg in "$@"; do
    case "$arg" in
      --instance=*) instance="${arg#--instance=}" ;;
    esac
  done
  [[ -z "$instance" ]] && fatal "missing --instance=<name>"
  echo "$instance"
}

cmd_start() {
  local instance; instance=$(parse_instance "$@")
  local dir="$ESRD_HOME/$instance"
  local pidfile="$dir/esrd.pid"
  mkdir -p "$dir/logs"

  # Idempotent: if already running, exit 0 with a notice.
  if [[ -s "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    echo "esrd[$instance] already running (pid=$(cat "$pidfile"))"
    return 0
  fi

  # Command override for tests; otherwise run the real Phoenix server on
  # port 4001 (spec §7.1 default; url.py's DEFAULT_*_HUB_URL assumes it).
  local cmd="${ESRD_CMD_OVERRIDE:-cd runtime && PORT=4001 exec mix phx.server}"

  # Launch detached, redirect output, capture child pid. The subshell's
  # stdout/stderr must be redirected so the parent's captured streams
  # (subprocess.run(capture_output=True) in the scenario runner) can hit
  # EOF as soon as cmd_start's own echo finishes — otherwise the wait
  # on the grandchild keeps fds alive indefinitely.
  (
    cd "$(git rev-parse --show-toplevel)" || exit 1
    eval "$cmd" >"$dir/logs/stdout.log" 2>&1 &
    echo $! > "$pidfile"
    wait "$(cat "$pidfile")" 2>/dev/null || true
  ) >/dev/null 2>&1 &
  disown $! 2>/dev/null || true

  # Wait briefly for pidfile to appear; Phoenix often needs a few hundred
  # ms before it's reachable on the WS port, but pidfile is immediate.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -s "$pidfile" ]] && break
    sleep 0.05
  done
  [[ -s "$pidfile" ]] || fatal "esrd[$instance] failed to start (no pidfile)"
  echo "esrd[$instance] started (pid=$(cat "$pidfile"))"
}

cmd_stop() {
  local instance; instance=$(parse_instance "$@")
  local pidfile="$ESRD_HOME/$instance/esrd.pid"

  if [[ ! -s "$pidfile" ]]; then
    echo "esrd[$instance] not running (no pidfile)"
    return 0
  fi

  local pid; pid=$(cat "$pidfile")
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    # Wait up to 2 s for the process to exit, then SIGKILL.
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$pidfile"

  # Ephemeral smoke-* instances (final_gate.sh --live uses ``smoke-live``)
  # get aggressive state cleanup so the next loop iteration can start
  # fresh — wipe Python worker subprocesses + their pidfiles, AND the
  # default adapters.yaml the CLI's ``esr adapter add`` targets (the CLI
  # is not yet esrd-instance-aware in v0.1).
  if [[ "$instance" == smoke-* ]]; then
    pkill -f 'esr\.ipc\.(adapter_runner|handler_worker)' 2>/dev/null || true
    rm -f /tmp/esr-worker-*.pid /tmp/esr-worker-*.log 2>/dev/null
    rm -f "$ESRD_HOME/default/adapters.yaml" 2>/dev/null
  fi

  echo "esrd[$instance] stopped"
}

cmd_status() {
  local instance; instance=$(parse_instance "$@")
  local pidfile="$ESRD_HOME/$instance/esrd.pid"

  if [[ -s "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    echo "esrd[$instance] RUNNING (pid=$(cat "$pidfile"))"
  else
    echo "esrd[$instance] STOPPED"
    [[ -e "$pidfile" ]] && rm -f "$pidfile"
  fi
}

action="${1:-}"
shift || true
case "$action" in
  start)  cmd_start  "$@" ;;
  stop)   cmd_stop   "$@" ;;
  status) cmd_status "$@" ;;
  *)      fatal "usage: $0 {start|stop|status} --instance=<name>" ;;
esac
