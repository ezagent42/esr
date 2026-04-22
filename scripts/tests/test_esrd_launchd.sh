#!/usr/bin/env bash
set -u
tmp=$(mktemp -d)
export ESRD_HOME=$tmp
export ESR_INSTANCE=default
export ESR_REPO_DIR=$(pwd)
export ESRD_CMD_OVERRIDE='sleep 10'

scripts/esrd-launchd.sh &
pid=$!
sleep 1

[[ -f "$tmp/default/esrd.port" ]] || { echo "FAIL: port file missing"; kill $pid; exit 1; }
port=$(cat "$tmp/default/esrd.port")
[[ "$port" =~ ^[0-9]+$ ]] || { echo "FAIL: port malformed '$port'"; kill $pid; exit 1; }

kill $pid 2>/dev/null
echo "OK"
