#!/usr/bin/env bash
# Convenience wrapper: `./esr.sh <subcmd>` instead of
# `uv run --project py esr <subcmd>`. Call from anywhere via absolute
# path or symlink — the wrapper resolves the repo root from $0 so cwd
# doesn't matter.
#
# PR-K (2026-04-28) added the `--env={prod,dev}` first-arg shorthand
# so operators don't have to spell out `ESRD_HOME=~/.esrd[-dev]`
# every call. Mapping mirrors `_HOME_MAP` in
# adapters/feishu/src/esr_feishu/...:
#   --env=prod → ESRD_HOME=~/.esrd      (default — same as no flag)
#   --env=dev  → ESRD_HOME=~/.esrd-dev
# Operators who set ESRD_HOME explicitly win — the wrapper only sets
# the env var when it isn't already set.
#
# Long-term plan is to replace this wrapper with a packaged binary
# (PyInstaller / shiv / pex) so operators don't need uv on PATH.
# Tracked at docs/futures/esr-cli-binary.md.
#
# Usage examples:
#   ./esr.sh status
#   ./esr.sh --env=dev adapter add ESR开发助手 --type feishu --app-id ... --app-secret ...
#   ./esr.sh --env=prod actors list
#   ESRD_HOME=~/.esrd-dev ./esr.sh actors list           # (still works)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# PR-K: parse a leading `--env=prod` / `--env=dev` shorthand. Must be
# the FIRST argument so we don't compete with subcommands that have
# their own `--env` flags (e.g. `cmd run --env KEY=VAL`).
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

if ! command -v uv >/dev/null 2>&1; then
  echo "esr.sh: 'uv' not found on PATH; install via https://docs.astral.sh/uv/" >&2
  exit 1
fi

exec uv run --project "$SCRIPT_DIR/py" esr "$@"
