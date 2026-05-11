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
#   ./tools/wipe-esrd-home.sh [--dev | --prod] [--dry-run] [--keep-adapters]
#
# OPTIONS:
#   --dev             Target ~/.esrd-dev (or $ESRD_HOME if set). Default.
#   --prod            Target ~/.esrd (or $ESRD_HOME if set).
#   --dry-run         Print what would be deleted; do NOT delete anything.
#   --keep-adapters   Preserve <TARGET>/<instance>/adapters/ subtree. Use when
#                     re-bootstrapping state but you don't want to re-fetch
#                     adapter credentials (app_id/app_secret) from the Feishu
#                     console. Bootstrap will resume the existing adapter
#                     sidecars from disk. Added 2026-05-11 after the wipe
#                     blast-radius incident: adapter credentials are operator
#                     secrets that don't reconstitute from bootstrap.
#
# SPEC: docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md §11
#       (post-deploy migration steps, D7 wipe procedure)
#       and docs/superpowers/specs/2026-05-08-session-first-default-resolution.md
#       §6 (D6 — old `default` workspace must be wiped before first boot
#       of post-2026-05-08 ESR).
set -euo pipefail

MODE="--dev"
DRY_RUN=false
KEEP_ADAPTERS=false

for arg in "$@"; do
  case "$arg" in
    --dev)            MODE="--dev"  ;;
    --prod)           MODE="--prod" ;;
    --dry-run)        DRY_RUN=true  ;;
    --keep-adapters)  KEEP_ADAPTERS=true ;;
    *)
      echo "Usage: $0 [--dev | --prod] [--dry-run] [--keep-adapters]" >&2
      exit 1
      ;;
  esac
done

if [[ "$MODE" == "--dev" ]]; then
  TARGET="${ESRD_HOME:-${HOME}/.esrd-dev}"
elif [[ "$MODE" == "--prod" ]]; then
  TARGET="${ESRD_HOME:-${HOME}/.esrd}"
fi

echo "Target:         ${TARGET}"
echo "Mode:           ${MODE#--}"
echo "Keep adapters:  ${KEEP_ADAPTERS}"

if [[ "$DRY_RUN" == "true" ]]; then
  if [[ "$KEEP_ADAPTERS" == "true" ]]; then
    echo "[dry-run] Would delete all contents of ${TARGET} EXCEPT */adapters/."
  else
    echo "[dry-run] Would delete all contents of: ${TARGET}"
  fi
  echo "[dry-run] The directory itself is preserved. ESR Bootstrap rebuilds on first boot."
  exit 0
fi

echo ""
if [[ "$KEEP_ADAPTERS" == "true" ]]; then
  echo "WARNING: This will destroy all sessions, workspaces, plugin configs, and"
  echo "agent state inside:"
  echo "  ${TARGET}"
  echo "Adapter subtrees (*/adapters/) are PRESERVED."
else
  echo "WARNING: This will destroy all sessions, workspaces, plugin configs,"
  echo "ADAPTER REGISTRATIONS (including app_secret), and agent state inside:"
  echo "  ${TARGET}"
  echo "If you want to preserve adapter credentials, re-run with --keep-adapters."
fi
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

if [[ "$KEEP_ADAPTERS" == "true" ]]; then
  # Stage adapter subtrees aside, wipe everything else, restore.
  # Adapter subtrees live at $TARGET/<instance>/adapters/. We find them
  # by glob rather than hard-coding "default" so multi-instance setups
  # work uniformly.
  STAGING="$(mktemp -d)"
  trap 'rm -rf "$STAGING"' EXIT

  shopt -s nullglob
  for adapter_dir in "$TARGET"/*/adapters; do
    instance="$(basename "$(dirname "$adapter_dir")")"
    mkdir -p "$STAGING/$instance"
    mv "$adapter_dir" "$STAGING/$instance/adapters"
    echo "Staged: $instance/adapters"
  done
  shopt -u nullglob

  find "$TARGET" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

  shopt -s nullglob
  for staged_instance in "$STAGING"/*; do
    instance="$(basename "$staged_instance")"
    mkdir -p "$TARGET/$instance"
    mv "$staged_instance/adapters" "$TARGET/$instance/adapters"
    echo "Restored: $instance/adapters"
  done
  shopt -u nullglob
else
  # Default: remove all contents but preserve the directory itself.
  # Bootstrap expects the directory to already exist; it creates all
  # subdirectories (instances/, sessions/, plugins.yaml, etc.) on first boot.
  find "$TARGET" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
fi

echo "Wiped: ${TARGET}"
echo "Start esrd to rebuild from Bootstrap."
