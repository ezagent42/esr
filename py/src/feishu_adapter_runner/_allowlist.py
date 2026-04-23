"""Allowlist of adapter names this sidecar is willing to host.

Kept in its own module so :mod:`Esr.WorkerSupervisor`-side tests (Elixir)
and parametrised Python dispatch tests can import the exact same source
of truth. See :mod:`feishu_adapter_runner.__main__` for how it's fed
into :func:`_adapter_common.main.build_main`.
"""
from __future__ import annotations

#: Only Feishu instances may enter this sidecar. An empty / wrong
#: ``--adapter`` causes :func:`_adapter_common.main.build_main` to exit
#: with code 2 before any adapter factory is loaded.
ALLOWED_ADAPTERS: frozenset[str] = frozenset({"feishu"})
