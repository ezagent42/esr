#!/usr/bin/env bash
set -u
tmp=$(mktemp -d)
export ESRD_HOME=$tmp
export ESRD_CMD_OVERRIDE='sleep 60'  # don't actually start mix

# Test: --port=12345 respected
scripts/esrd.sh start --instance=default --port=12345 >/dev/null
port=$(cat "$tmp/default/esrd.port" 2>/dev/null)
[[ "$port" == "12345" ]] || { echo "FAIL: port was '$port' expected '12345'"; exit 1; }
scripts/esrd.sh stop --instance=default >/dev/null

# Test: no --port picks a free port
scripts/esrd.sh start --instance=default >/dev/null
port=$(cat "$tmp/default/esrd.port" 2>/dev/null)
[[ "$port" =~ ^[0-9]+$ ]] || { echo "FAIL: port file absent or malformed: '$port'"; exit 1; }
[[ "$port" -gt 1024 ]] || { echo "FAIL: port $port below 1024"; exit 1; }
scripts/esrd.sh stop --instance=default >/dev/null

echo "OK"
