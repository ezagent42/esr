"""Shared fixtures for the Feishu adapter test suite.

Lane A (the adapter-side `msg.send` gate + deny-DM dispatch) was
removed 2026-04-26 — auth lives entirely in Lane B (Elixir runtime,
`peer_server.ex:236-274`). The pre-existing
`allow_all_capabilities` / `write_allow_all_capabilities` fixtures
that sat here to satisfy Lane A's gate are gone with it; nothing in
the adapter needs `capabilities_path` at AdapterConfig anymore.

Migration note: `docs/notes/auth-lane-a-removal.md`.
"""
from __future__ import annotations
