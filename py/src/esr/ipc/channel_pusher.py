"""ChannelPusher — bridge from :class:`ChannelClient` to the
:class:`AdapterPusher` / pusher-protocol consumed by
:func:`_adapter_common.runner_core.directive_loop` and
:func:`_adapter_common.runner_core.event_loop` (Phase 8a F13).

``directive_loop`` / ``event_loop`` want an object with
``source_uri: str`` and ``async def push_envelope(env)``. Phoenix
Channels' client exposes the different ``push(topic, event, payload)``
shape. This module collapses the two.
"""
from __future__ import annotations

from typing import Any, Protocol


class _ChannelLike(Protocol):
    """Minimum surface a ChannelClient must offer."""

    async def push(self, topic: str, event: str, payload: dict[str, Any]) -> None: ...


class ChannelPusher:
    """Adapter layer: implements the pusher-protocol by delegating to
    :class:`ChannelClient.push` on a fixed topic.

    ``source_uri`` is the provenance URI stamped on outgoing envelopes
    (envelope["source"]). By convention it is built from the same
    components as the topic via :func:`esr.uri.build_path` —
    ``esr://localhost/adapters/<platform>/<instance_id>`` (path-style
    RESTful, see 2026-04-27 actor-topology-routing spec §3 + PR-B URI
    migration). The ``topic`` is the underlying Phoenix channel name
    (``adapter:<name>/<instance>`` or ``handler:<module>/<worker>``,
    legacy colon-style — unchanged); pushes use ``topic``, envelopes
    use ``source_uri``.
    """

    def __init__(self, *, client: _ChannelLike, topic: str, source_uri: str) -> None:
        self._client = client
        self.topic = topic
        self.source_uri = source_uri

    async def push_envelope(self, envelope: dict[str, Any]) -> None:
        """Forward an envelope dict through the underlying channel."""
        await self._client.push(self.topic, "envelope", envelope)
