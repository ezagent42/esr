#!/usr/bin/env bash
# scripts/esr-cc.sh — ESR v0.2 CC session launcher (spec §3.5 / §5.2).
#
# Spawned inside a tmux window by Topology.Instantiator's init_directive
# (or manually by an operator); reads the workspace config from
# `ESR_WORKSPACE` + `~/.esrd/<instance>/workspaces.yaml`, renders
# `.mcp.json` at the workspace cwd, and execs `claude` with the right
# flags for stdio-parented esr-channel MCP.
set -euo pipefail

: "${ESR_WORKSPACE:?must be set (workspace name)}"
: "${ESR_SESSION_ID:?must be set (session_id)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ESRD_INSTANCE="${ESRD_INSTANCE:-default}"
WORKSPACES_YAML="$HOME/.esrd/$ESRD_INSTANCE/workspaces.yaml"

# Source shell rcs (tmux non-interactive shells need PATH setup)
for rc in "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.bashrc"; do
  [ -f "$rc" ] && source "$rc" 2>/dev/null || true
done

# Fallback PATH additions
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"

# Local overrides (proxy, secrets)
[ -f "$SCRIPT_DIR/esr-cc.local.sh" ] && source "$SCRIPT_DIR/esr-cc.local.sh"

# MCP secrets
[ -f "$REPO_ROOT/.mcp.env" ] && set -a && source "$REPO_ROOT/.mcp.env" && set +a

# Resolve workspace from YAML
if ! command -v yq &>/dev/null; then
  echo "esr-cc.sh: yq not installed (brew install yq)" >&2
  exit 2
fi

if [ ! -f "$WORKSPACES_YAML" ]; then
  echo "esr-cc.sh: workspaces.yaml not found at $WORKSPACES_YAML" >&2
  exit 2
fi

ws="$ESR_WORKSPACE"
cwd=$(yq -r ".workspaces.${ws}.cwd // \"\"" "$WORKSPACES_YAML")
role=$(yq -r ".workspaces.${ws}.role // \"dev\"" "$WORKSPACES_YAML")
chats_json=$(yq -o=json -I=0 ".workspaces.${ws}.chats // []" "$WORKSPACES_YAML")

if [ -z "$cwd" ] || [ "$cwd" = "null" ]; then
  echo "esr-cc.sh: workspace '$ws' not declared in $WORKSPACES_YAML" >&2
  exit 2
fi

# Expand ~ in cwd
cwd="${cwd/#\~/$HOME}"
mkdir -p "$cwd"
cd "$cwd"

# Write .mcp.json at workspace cwd
cat > .mcp.json <<EOF
{
  "mcpServers": {
    "esr-channel": {
      "command": "uv",
      "args": ["run", "--project", "$REPO_ROOT/py", "python", "-m", "esr_cc_mcp.channel"],
      "env": {
        "ESR_ESRD_URL": "${ESR_ESRD_URL:-ws://127.0.0.1:4001}",
        "ESR_SESSION_ID": "$ESR_SESSION_ID",
        "ESR_WORKSPACE": "$ws",
        "ESR_CHAT_IDS": $chats_json,
        "ESR_ROLE": "$role"
      }
    }
  }
}
EOF

# Compute claude --resume handling (spec §3.3 CC session resumption)
session_ids_yaml="$HOME/.esrd/$ESRD_INSTANCE/session-ids.yaml"
resume_arg=""
if [ -f "$session_ids_yaml" ]; then
  prior_session_id=$(yq -r ".sessions.\"${ws}:${ESR_SESSION_ID}\" // \"\"" "$session_ids_yaml")
  if [ -n "$prior_session_id" ] && [ "$prior_session_id" != "null" ]; then
    resume_arg="--resume $prior_session_id"
  fi
fi

# Build claude command
CLAUDE_FLAGS=(
  --permission-mode bypassPermissions
  --dangerously-load-development-channels server:esr-channel
  --mcp-config .mcp.json
  --add-dir "$cwd"
)

settings_file="$REPO_ROOT/roles/$role/settings.json"
[ -f "$settings_file" ] && CLAUDE_FLAGS+=(--settings "$settings_file")

# Exec claude (replacing the shell process; tmux remains parent)
exec claude $resume_arg "${CLAUDE_FLAGS[@]}"
