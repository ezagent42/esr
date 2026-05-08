#!/usr/bin/env bash
# Convenience wrapper: `./esr.sh <subcmd>` instead of
# `runtime/esr <subcmd>`. Call from anywhere via absolute path or
# symlink — the wrapper resolves the repo root from $0 so cwd
# doesn't matter.
#
# 2026-05-06: Python click CLI deleted; this wrapper now forwards to
# the Elixir escript at `runtime/esr`. The `--env={prod,dev}`
# first-arg shorthand still works:
#   --env=prod → ESRD_HOME=~/.esrd       (default — same as no flag)
#   --env=dev  → ESRD_HOME=~/.esrd-dev
# Operators who set ESRD_HOME explicitly win — the wrapper only sets
# the env var when it isn't already set.
#
# The escript is built by `mix escript.build` in `runtime/`. If
# `runtime/esr` is missing or stale, run that command.
#
# Usage examples:
#   ./esr.sh actors list
#   ./esr.sh --env=dev adapter_add type=feishu instance_id=ESR开发助手 \
#       app_id=... app_secret=...
#   ./esr.sh --env=prod doctor mode=system
#   ESRD_HOME=~/.esrd-dev ./esr.sh actors list           # (still works)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse a leading `--env=prod` / `--env=dev` shorthand. Must be
# the FIRST argument so we don't compete with subcommands.
case "${1:-}" in
  --env=prod)
    shift
    : "${ESRD_HOME:=$HOME/.esrd}"
    ;;
  --env=dev)
    shift
    : "${ESRD_HOME:=$HOME/.esrd-dev}"
    ;;
  --env=*)
    echo "esr.sh: unknown --env value '${1#--env=}' (expected prod|dev)" >&2
    exit 2
    ;;
esac
export ESRD_HOME

ESCRIPT="$SCRIPT_DIR/runtime/esr"
if [[ ! -x "$ESCRIPT" ]]; then
  echo "esr.sh: escript not found at $ESCRIPT" >&2
  echo "        run \`cd $SCRIPT_DIR/runtime && mix escript.build\`" >&2
  exit 1
fi

exec "$ESCRIPT" "$@"
