"""Feishu adapter entry point (PRD 04 F05-F15).

Registered with the ESR runtime at import time via ``@esr.adapter``.
The factory is deliberately pure (PRD 04 F02): it stores config
and returns an instance — no network calls, no lark_oapi.Client
construction. Actual I/O happens lazily inside ``on_directive`` /
``emit_events``, where errors can be surfaced as directive acks
rather than crashing the process.

Directive/event implementations land in F06+ (lazy lark client,
send_message, react, send_card, pin/unpin, WS listener, rate
limiting). This file currently covers F05 (registration) and the
F02 purity guarantee.
"""

from __future__ import annotations

from typing import Any

from esr.adapter import AdapterConfig, adapter


@adapter(
    name="feishu",
    allowed_io={
        "lark_oapi": "*",
        "aiohttp": "*",
        "http": ["open.feishu.cn"],
    },
)
class FeishuAdapter:
    """Adapter instance for a single Feishu app identity.

    One instance == one (app_id, app_secret) pair. The runtime may
    register many instances under different names (e.g. a
    ``feishu-shared`` app and a ``feishu-dev`` app) against the same
    adapter class.
    """

    def __init__(self, actor_id: str, config: AdapterConfig) -> None:
        self.actor_id = actor_id
        self._config = config
        self._lark_client: Any | None = None

    @staticmethod
    def factory(actor_id: str, config: AdapterConfig) -> FeishuAdapter:
        """Construct a FeishuAdapter — pure, no I/O (PRD 04 F02)."""
        return FeishuAdapter(actor_id=actor_id, config=config)

    def client(self) -> Any:
        """Return the (cached) ``lark_oapi.Client`` for this adapter.

        Lazy-initialised on first call (PRD 04 F06) so ``factory`` stays pure.
        """
        if self._lark_client is None:
            import lark_oapi

            self._lark_client = (
                lark_oapi.Client.builder()
                .app_id(self._config.app_id)
                .app_secret(self._config.app_secret)
                .build()
            )
        return self._lark_client
