"""Claude-Code adapter sidecar (PR-4b P4b-3).

Hosts the ``cc_mcp`` adapter (MCP-based out-of-process CC wrapper). Kept
as a dedicated sidecar so claude-code-family runtime concerns stay
separate from the Feishu adapter.

Launched via:

    python -m cc_adapter_runner --adapter cc_mcp \\
        --instance-id ... --url ...

``_allowlist.ALLOWED_ADAPTERS = frozenset({"cc_mcp"})``; an accidental
``--adapter feishu`` is refused with exit code 2.
"""
