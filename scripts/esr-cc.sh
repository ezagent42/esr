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
# PR-21σ 2026-05-01: support `ESRD_HOME` (set by launchd plist for
# esrd-prod and esrd-dev). Falls back to `~/.esrd` for legacy
# operator paths that didn't set the env var.
ESRD_HOME_DIR="${ESRD_HOME:-$HOME/.esrd}"
WORKSPACES_YAML="$ESRD_HOME_DIR/$ESRD_INSTANCE/workspaces.yaml"

# PR-21σ: explicit PATH only — do NOT source `~/.zshrc` etc. zsh
# rcs frequently contain zsh-only constructs (oh-my-posh, fzf-tab)
# that bash chokes on, and `set -e` then silently kills this script
# at the source line. Everything we actually need (yq, claude, uv) is
# in /opt/homebrew/bin or ~/.local/bin, both already covered below.
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
# PR-21c: schema bump — `cwd:` removed, `root:` added (main git repo).
# Per-session cwd is supplied by PR-21d's `/new-session` slash; until that
# lands, fall back to `root:` for the .mcp.json placement directory.
# `ESR_CWD` env var is the forward-compatible override that PR-21d's
# spawn path will set before invoking this script.
root=$(yq -r ".workspaces.${ws}.root // \"\"" "$WORKSPACES_YAML")
role=$(yq -r ".workspaces.${ws}.role // \"dev\"" "$WORKSPACES_YAML")
chats_json=$(yq -o=json -I=0 ".workspaces.${ws}.chats // []" "$WORKSPACES_YAML")

if [ -n "${ESR_CWD:-}" ]; then
  cwd="$ESR_CWD"
elif [ -n "$root" ] && [ "$root" != "null" ]; then
  cwd="$root"
else
  echo "esr-cc.sh: workspace '$ws' has no root: in $WORKSPACES_YAML and no ESR_CWD env var" >&2
  exit 2
fi

# Expand ~
cwd="${cwd/#\~/$HOME}"
mkdir -p "$cwd"
cd "$cwd"

# PR-21σ 2026-05-01: MCP env values must be strings (claude rejects
# the config with `Does not adhere to MCP server configuration schema`
# when ESR_CHAT_IDS comes through as a raw JSON array). JSON-encode
# the chats array as a string by escaping internal double quotes.
chats_string="${chats_json//\"/\\\"}"

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
        "ESR_CHAT_IDS": "$chats_string",
        "ESR_ROLE": "$role"
      }
    }
  }
}
EOF

# Compute claude --resume handling (spec §3.3 CC session resumption)
session_ids_yaml="$ESRD_HOME_DIR/$ESRD_INSTANCE/session-ids.yaml"
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
