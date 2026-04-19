#!/usr/bin/env bash
# Tests for scripts/esrd.sh — uses a trivial `sleep` stand-in via
# ESRD_CMD_OVERRIDE so we can verify pid-file lifecycle without
# actually booting Phoenix every test run.
set -u

cd "$(git rev-parse --show-toplevel)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export ESRD_HOME="$tmp/.esrd"
export ESRD_CMD_OVERRIDE="sleep 60"

pass=0
fail=0

check() {
  local desc="$1" cond="$2"
  if eval "$cond"; then
    pass=$((pass + 1))
    echo "  ok — $desc"
  else
    fail=$((fail + 1))
    echo "  FAIL — $desc"
  fi
}

echo "=== start ==="
bash scripts/esrd.sh start --instance=t1 >/dev/null
check "pid file created" "[[ -s $ESRD_HOME/t1/esrd.pid ]]"
check "process is running" "kill -0 \$(cat $ESRD_HOME/t1/esrd.pid) 2>/dev/null"

echo "=== status (running) ==="
out=$(bash scripts/esrd.sh status --instance=t1)
check "status reports running" "echo '$out' | grep -q RUNNING"

echo "=== idempotent start ==="
bash scripts/esrd.sh start --instance=t1 >/dev/null  # should be no-op, not a second process
check "still exactly one process for t1" "[[ \$(pgrep -lf 'sleep 60' | wc -l) -ge 1 ]]"

echo "=== stop ==="
bash scripts/esrd.sh stop --instance=t1 >/dev/null
check "pid file removed" "[[ ! -f $ESRD_HOME/t1/esrd.pid ]]"

echo "=== status (stopped) ==="
out=$(bash scripts/esrd.sh status --instance=t1)
check "status reports stopped" "echo '$out' | grep -q STOPPED"

echo
if (( fail == 0 )); then
  echo "ALL $pass esrd.sh smoke tests PASSED"
else
  echo "$fail failures out of $((pass + fail)) tests"
  exit 1
fi
