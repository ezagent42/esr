"""Allowlist for cc_adapter_runner — tmux + MCP variants share a sidecar.

Both adapters live in this process because they have identical wire
semantics (single adapter instance per invocation, Phoenix channel join
on ``adapter:<name>/<id>``) and share many IO dependencies. Separating
them into two sidecars would double the RSS without isolating any
failure mode.
"""
from __future__ import annotations

#: ``cc_tmux``: tmux-attached long-lived CC REPL. ``cc_mcp``: MCP-based
#: out-of-process CC wrapper. Both are claude-code-family adapters.
ALLOWED_ADAPTERS: frozenset[str] = frozenset({"cc_tmux", "cc_mcp"})
