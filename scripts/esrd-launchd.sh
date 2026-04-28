#!/usr/bin/env bash
# Foreground launchd wrapper — runs `mix phx.server` in the foreground
# so launchd supervises beam.smp directly (not a detached grandchild).
#
# Env vars from plist:
#   ESRD_HOME        - runtime state root (default: ~/.esrd)
#   ESR_INSTANCE     - instance name (default: default)
#   ESR_REPO_DIR     - code checkout dir to cd into
#   ESRD_CMD_OVERRIDE - for testing; replaces the mix command

set -u
ESRD_HOME="${ESRD_HOME:-$HOME/.esrd}"
ESR_INSTANCE="${ESR_INSTANCE:-default}"
dir="$ESRD_HOME/$ESR_INSTANCE"
mkdir -p "$dir/logs"

# Pre-select a free port (fallback path). Future: pass PORT=0 for post-bind.
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); p=s.getsockname()[1]; s.close(); print(p)')
echo "$port" > "$dir/esrd.port"

cd "${ESR_REPO_DIR:-$(git rev-parse --show-toplevel)}"

# launchd's default PATH is /usr/bin:/bin:/usr/sbin:/sbin — Homebrew's
# mix lives at /opt/homebrew/bin (Apple Silicon) or /usr/local/bin
# (Intel). Probe both so this script works on either architecture
# without operator intervention. Fail fast with a readable message
# if mix isn't found anywhere — beats launchd's exit 127 in stderr.
for prefix in /opt/homebrew /usr/local; do
  if [ -x "$prefix/bin/mix" ]; then
    export PATH="$prefix/bin:$PATH"
    break
  fi
done

if ! command -v mix >/dev/null 2>&1; then
  echo "esrd-launchd: mix not on PATH after probing /opt/homebrew/bin and /usr/local/bin (PATH=$PATH)" >&2
  exit 1
fi

export PORT=$port
exec ${ESRD_CMD_OVERRIDE:-mix phx.server}
