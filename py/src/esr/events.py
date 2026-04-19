"""Event + Directive dataclasses (PRD 02 F03).

Two sibling types — both frozen, both carrying a single opaque `args`
dict. `Event` flows inbound from adapter to runtime; `Directive`
flows outbound from runtime to adapter (spec §5.3).

Event additionally tracks `source` (the originating adapter's full
`esr://` URI) so cross-boundary routing can identify the producer.
`from_envelope` deserialises the subset of an IPC payload the
handler actually sees — the runtime strips the outer envelope fields
(id, ts, type) before passing the event to the handler.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class Event:
    """An inbound event from an external system (spec §5.3)."""

    source: str
    event_type: str
    args: dict[str, Any]

    @classmethod
    def from_envelope(cls, envelope: dict[str, Any]) -> Event:
        """Build an Event from an IPC payload's inner fields.

        The runtime peels the outer `{id, ts, type, payload}` envelope
        and passes `payload`'s relevant keys. We accept either the
        full envelope or the already-stripped inner dict.
        """
        if "payload" in envelope and "event_type" in envelope.get("payload", {}):
            inner = envelope["payload"]
            source = envelope.get("source", "")
        else:
            inner = envelope
            source = envelope.get("source", "")

        return cls(
            source=source,
            event_type=inner["event_type"],
            args=dict(inner.get("args", {})),
        )


@dataclass(frozen=True)
class Directive:
    """An outbound directive to an adapter (spec §5.3)."""

    adapter: str
    action: str
    args: dict[str, Any]
