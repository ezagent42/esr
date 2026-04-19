#!/usr/bin/env bash
# spawn_worker.sh — detach a worker command and print its pid on stdout.
#
# Used by Esr.WorkerSupervisor to launch Python adapter_runner /
# handler_worker subprocesses. Written as a standalone script because
# bash-in-bash-in-elixir was hanging on FD inheritance — doing the
# daemonisation dance here and returning promptly keeps the Elixir
# System.cmd path unblocked.
#
# Usage:
#   scripts/spawn_worker.sh <log_path> <cmd...>
#
# On exit:
#   stdout: <pid>\n         (the backgrounded process pid)
#   exit 0
set -u

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <log_path> <cmd...>" >&2
  exit 2
fi

log_path="$1"
shift

# Start the worker detached:
#   - close stdin / stdout / stderr (inherits /dev/null / log file)
#   - disown from the script's job table
# The & sends the job to the background. We grab $! before disowning.
"$@" </dev/null >"$log_path" 2>&1 &
pid=$!
disown "$pid" 2>/dev/null || true

# Close our own stdout/stderr BEFORE printing the pid — we keep a single
# write for stdout by using a subshell that exits after the echo.
echo "$pid"
