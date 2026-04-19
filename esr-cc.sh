#!/bin/bash
# ESR Claude Code launcher — wraps `claude` with project PATH + local overrides.
# Mirrors cc-openclaw.sh's shape; the esr-cc.local.sh override file is gitignored.

set -e

# Source shell config
for f in "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.bashrc"; do
    [ -f "$f" ] && source "$f" 2>/dev/null
done

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Local overrides (proxy, API keys, machine-specific)
[ -f "$SCRIPT_DIR/esr-cc.local.sh" ] && source "$SCRIPT_DIR/esr-cc.local.sh"

# MCP server secrets
[ -f "$SCRIPT_DIR/.mcp.env" ] && set -a && source "$SCRIPT_DIR/.mcp.env" && set +a

# Launch claude
exec claude "$@"
