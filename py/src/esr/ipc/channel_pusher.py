"""ChannelPusher — bridge from :class:`ChannelClient` to the
:class:`AdapterPusher` / pusher-protocol consumed by
:func:`esr.ipc.adapter_runner.directive_loop` and
:func:`esr.ipc.adapter_runner.event_loop` (Phase 8a F13).

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

    ``source_uri`` is reused as the topic name — by v0.1 convention they
    are identical (``adapter:<name>/<instance>`` or
    ``handler:<module>/<worker>``).
    """

    def __init__(self, *, client: _ChannelLike, topic: str, source_uri: str) -> None:
        self._client = client
        self.topic = topic
        self.source_uri = source_uri

    async def push_envelope(self, envelope: dict[str, Any]) -> None:
        """Forward an envelope dict through the underlying channel."""
        await self._client.push(self.topic, "envelope", envelope)
