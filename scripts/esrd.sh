#!/usr/bin/env bash
# scripts/esrd.sh — per-instance runtime daemon manager (Phase 8b).
#
# Usage:
#   scripts/esrd.sh start  --instance=<name>
#   scripts/esrd.sh stop   --instance=<name> [--launchd-restart]
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
#
# DUAL-MANAGER WARNING (added 2026-05-10):
#   When esrd is launchd-managed (per scripts/launchd/install.sh installs
#   ~/Library/LaunchAgents/com.ezagent.esrd-${instance}.plist with
#   KeepAlive=true), this script's start/stop ARE NOT the right tool —
#   launchd is the lifecycle manager. The pidfile-based stop here will
#   succeed in killing the BEAM, but launchd auto-respawns within seconds,
#   making the operator believe their stop was ineffective. Use:
#     scripts/launchd/install.sh --env=<dev|prod|both>     (one-time setup)
#     scripts/launchd/uninstall.sh --env=<dev|prod|both>   (full unload)
#     launchctl kickstart -k gui/$UID/com.ezagent.esrd-<instance>  (restart)
#
#   This script (esrd.sh) is for the pidfile-based dev workflow when no
#   launchd plist is installed. cmd_stop detects an installed plist and
#   refuses to act with a pointer to the right tool, unless invoked with
#   --launchd-restart which delegates to `launchctl kickstart -k`.
#   See docs/operations/esrd-management.md for the full operator guide.
set -u

# Auto-source local env overrides if present. Gitignored .env.local is the
# supported place for operator secrets like ESR_BOOTSTRAP_PRINCIPAL_ID
# (user IM id → auto-seeded capabilities.yaml wildcard on first boot).
# See .env.local.example for the full list. Shell `set -u` is fine — the
# file is `export`-based so undefined vars never reach this layer.
_ESRD_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "${_ESRD_REPO_ROOT}/.env.local" ] && . "${_ESRD_REPO_ROOT}/.env.local"

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

  # Parse optional --port=<N>
  local port=""
  for arg in "$@"; do
    case "$arg" in
      --port=*) port="${arg#--port=}" ;;
    esac
  done

  # Pre-select a free port if not specified
  if [[ -z "$port" ]]; then
    port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); p=s.getsockname()[1]; s.close(); print(p)')
  fi

  # Write port file BEFORE exec
  echo "$port" > "$dir/esrd.port"

  # Command override for tests; otherwise run the real Phoenix server on
  # the selected port (spec §7.1 default 4001; url.py's DEFAULT_*_HUB_URL assumes it).
  # ESR_INSTANCE must reach the mix process so the admin-queue watcher
  # (runtime/lib/esr/admin/command_queue/watcher.ex) opens the right
  # $ESRD_HOME/<instance>/admin_queue/pending/ directory — otherwise
  # commands submitted under a custom instance (e.g. PR-7's e2e runs)
  # land in a directory nobody watches and the caller times out.
  local cmd="${ESRD_CMD_OVERRIDE:-cd runtime && PORT=$port ESR_INSTANCE=$instance ESRD_HOME=$ESRD_HOME exec mix phx.server}"

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

is_launchd_managed() {
  # Returns 0 (true) if a launchd plist exists for this instance AND
  # `launchctl list` reports the label as loaded. Both checks matter:
  # a stale plist file with no loaded service should still fall through
  # to the pidfile path (the operator may have manually `bootout`-ed it
  # but not removed the file).
  local instance="$1"
  local label="com.ezagent.esrd-${instance}"
  local plist="${HOME}/Library/LaunchAgents/${label}.plist"
  [[ -f "$plist" ]] || return 1
  # `launchctl list` exits non-zero on filter miss, so just grep the
  # output (works on macOS 10.10+; user is on Darwin 25 per env).
  launchctl list 2>/dev/null | grep -q "${label}\$" || return 1
  return 0
}

cmd_stop() {
  local instance; instance=$(parse_instance "$@")
  local launchd_restart=0
  for arg in "$@"; do
    case "$arg" in
      --launchd-restart) launchd_restart=1 ;;
    esac
  done

  # 2026-05-10 fix: detect launchd-managed instance and refuse pidfile
  # stop. Without this, operator's `esrd.sh stop` succeeds at killing
  # the BEAM but launchd's KeepAlive=true respawns immediately — the
  # operator concludes their stop "didn't work" and the loop produces
  # zombie BEAMs from racing kill+respawn. The right tool is launchctl.
  if is_launchd_managed "$instance"; then
    local label="com.ezagent.esrd-${instance}"
    if (( launchd_restart )); then
      launchctl kickstart -k "gui/$(id -u)/${label}" 2>/dev/null || true
      echo "esrd[$instance] launchd-managed — kicked via launchctl kickstart -k gui/$(id -u)/${label}"
      return 0
    fi
    echo "esrd[$instance] is launchd-managed (${label}). Use 'scripts/launchd/uninstall.sh --env=${instance}' to fully stop, or 'launchctl kickstart -k gui/$(id -u)/${label}' to restart. Re-run with --launchd-restart to delegate the kickstart from this command. (See docs/operations/esrd-management.md for the full guide.)"
    return 0
  fi

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
  # is not yet esrd-instance-aware in v0.1). Worker .log files are
  # preserved under $ESRD_HOME/<instance>/logs/workers/ so post-mortem
  # debugging survives restarts.
  if [[ "$instance" == smoke-* ]]; then
    local worker_logs_dir="$ESRD_HOME/$instance/logs/workers"
    mkdir -p "$worker_logs_dir"
    for log in /tmp/esr-worker-*.log; do
      [ -f "$log" ] || continue
      mv "$log" "$worker_logs_dir/" 2>/dev/null || true
    done

    # PR-4b: adapter_runner was split into per-type sidecars; kill the
    # legacy monolith (deprecation shim) as well as the new sidecars.
    pkill -f 'esr\.ipc\.(adapter_runner|handler_worker)|python -m (feishu|cc|generic)_adapter_runner' 2>/dev/null || true
    rm -f /tmp/esr-worker-*.pid 2>/dev/null
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
