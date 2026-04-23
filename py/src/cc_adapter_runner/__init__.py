"""Claude-Code adapter sidecar (PR-4b P4b-3).

Hosts both ``cc_tmux`` (the tmux-wrapped CC process adapter) and
``cc_mcp`` (the MCP-based adapter) instances. They share wire protocol,
launcher shape, and reconnect semantics — a single sidecar keeps the
process count lower without mixing them with Feishu.

Launched via:

    python -m cc_adapter_runner --adapter cc_tmux|cc_mcp \\
        --instance-id ... --url ...

``_allowlist.ALLOWED_ADAPTERS = frozenset({"cc_tmux", "cc_mcp"})``; an
accidental ``--adapter feishu`` is refused with exit code 2.
"""
