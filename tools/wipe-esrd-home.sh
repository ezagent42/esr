#!/usr/bin/env bash
# tools/wipe-esrd-home.sh
#
# PURPOSE: Run before first boot of post-2026-05-07 ESR.
# Old ESRD_HOME state (workspaces.yaml, single-agent session state,
# username-keyed dirs) is incompatible with the new UUID-based layout.
# Bootstrap rebuilds all required directories and config from scratch on
# first boot.
#
# USAGE:
#   ./tools/wipe-esrd-home.sh [--dev | --prod] [--dry-run]
#
# OPTIONS:
#   --dev      Target ~/.esrd-dev (or $ESRD_HOME if set). Default.
#   --prod     Target ~/.esrd (or $ESRD_HOME if set).
#   --dry-run  Print what would be deleted; do NOT delete anything.
#
# SPEC: docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md §11
#       (post-deploy migration steps, D7 wipe procedure)
set -euo pipefail

MODE="--dev"
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --dev)     MODE="--dev"  ;;
    --prod)    MODE="--prod" ;;
    --dry-run) DRY_RUN=true  ;;
    *)
      echo "Usage: $0 [--dev | --prod] [--dry-run]" >&2
      exit 1
      ;;
  esac
done

if [[ "$MODE" == "--dev" ]]; then
  TARGET="${ESRD_HOME:-${HOME}/.esrd-dev}"
elif [[ "$MODE" == "--prod" ]]; then
  TARGET="${ESRD_HOME:-${HOME}/.esrd}"
fi

echo "Target: ${TARGET}"
echo "Mode:   ${MODE#--}"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "[dry-run] Would delete all contents of: ${TARGET}"
  echo "[dry-run] The directory itself is preserved. ESR Bootstrap rebuilds on first boot."
  exit 0
fi

echo ""
echo "WARNING: This will destroy all sessions, workspaces, plugin configs, and"
echo "agent state inside:"
echo "  ${TARGET}"
echo ""
echo "Ensure any needed data (workspace folders, plugin keys, Feishu credentials)"
echo "is noted elsewhere before continuing."
echo ""
read -rp "Type 'yes' to confirm wipe: " confirm
if [[ "$confirm" != "yes" ]]; then
  echo "Aborted."
  exit 1
fi

if [[ ! -d "$TARGET" ]]; then
  echo "Directory does not exist; nothing to wipe: ${TARGET}"
  exit 0
fi

# Remove contents but preserve the directory itself.
# Bootstrap expects the directory to already exist; it creates all
# subdirectories (instances/, sessions/, plugins.yaml, etc.) on first boot.
find "$TARGET" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

echo "Wiped: ${TARGET}"
echo "Start esrd to rebuild from Bootstrap."
