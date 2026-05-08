"""Allowlist for cc_adapter_runner — only the cc_mcp adapter lives here.

The allowlist is kept (rather than collapsed into a single string) so the
sidecar's CLI surface stays uniform with the other runners and so adding a
future cc-family variant remains a one-line change.
"""
from __future__ import annotations

#: ``cc_mcp``: MCP-based out-of-process CC wrapper.
ALLOWED_ADAPTERS: frozenset[str] = frozenset({"cc_mcp"})
