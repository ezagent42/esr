"""esr:// URI parser + builder (PRD 02 F15, spec §7.5 + 2026-04-27 actor-topology-routing extension).

Canonical forms::

    esr://[org@]host[:port]/<type>/<id>[?k=v&...]                     # legacy 2-segment
    esr://[org@]host[:port]/<type>(/<seg>)+[?k=v&...]                 # path-style RESTful

Legacy 2-segment types (still emitted today): ``adapter``, ``actor``,
``command``. Path-style RESTful types (introduced 2026-04-27):
``adapters``, ``workspaces``, ``chats``, ``users``, ``sessions`` —
followed by 1+ more path segments forming a hierarchical resource
address.

Empty host is a hard error (paths like ``esr:///foo/bar`` are
ill-formed — the host is the anchor for cross-boundary routing).

The parser is intentionally strict: anything the spec doesn't allow
is rejected with ``ValueError``. This is the Python counterpart of
``Esr.Uri`` in the Elixir runtime (PRD 01 F17) — the two must agree
on wire-level URI strings for IPC.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from types import MappingProxyType
from typing import Any
from urllib.parse import parse_qsl

# Legacy types: 2-segment URIs (single id, no slashes inside).
_LEGACY_TYPES = frozenset({"adapter", "actor", "command"})

# Path-style RESTful types: 2+ segment URIs (hierarchical resource path).
_PATH_STYLE_TYPES = frozenset({"adapters", "workspaces", "chats", "users", "sessions"})

_VALID_TYPES = _LEGACY_TYPES | _PATH_STYLE_TYPES


def legacy_types() -> frozenset[str]:
    """Return the legacy type set (single-id, 2-segment URIs)."""
    return _LEGACY_TYPES


def path_style_types() -> frozenset[str]:
    """Return the path-style RESTful type set (introduced 2026-04-27)."""
    return _PATH_STYLE_TYPES


@dataclass(frozen=True)
class EsrURI:
    """Parsed ``esr://`` URI.

    For legacy 2-segment URIs, ``type``/``id`` carry the parsed pair and
    ``segments`` is ``[type, id]``. For path-style URIs, ``type`` is the
    first segment, ``id`` is the last segment, and ``segments`` is the
    full path (3+ entries).
    """

    org: str | None
    host: str
    port: int | None
    type: str
    id: str
    segments: tuple[str, ...] = field(default=())
    params: MappingProxyType[str, str] = field(
        default_factory=lambda: MappingProxyType({})
    )

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, EsrURI):
            return NotImplemented
        return (
            self.org == other.org
            and self.host == other.host
            and self.port == other.port
            and self.type == other.type
            and self.id == other.id
            and tuple(self.segments) == tuple(other.segments)
            and dict(self.params) == dict(other.params)
        )

    def __hash__(self) -> int:
        return hash(
            (
                self.org,
                self.host,
                self.port,
                self.type,
                self.id,
                tuple(self.segments),
                tuple(sorted(self.params.items())),
            )
        )


def parse(s: str) -> EsrURI:
    """Parse an ``esr://`` URI string into an ``EsrURI``."""
    if not s.startswith("esr://"):
        raise ValueError(f"expected esr:// scheme; got {s!r}")
    rest = s[len("esr://") :]

    # Split authority / path ? query
    path_and_query = rest
    query = ""
    if "?" in path_and_query:
        path_and_query, query = path_and_query.split("?", 1)

    authority, _, raw_path = path_and_query.partition("/")
    if raw_path == "" and "/" not in path_and_query:
        raise ValueError(f"missing path in {s!r}")

    # authority = [org@]host[:port]
    org: str | None = None
    if "@" in authority:
        org, _, authority = authority.partition("@")
        if org == "":
            raise ValueError(f"empty org in {s!r}")

    host_str, _, port_str = authority.partition(":")
    if host_str == "":
        raise ValueError(f"empty host in {s!r}")

    port: int | None = None
    if port_str:
        try:
            port = int(port_str)
        except ValueError as exc:
            raise ValueError(f"invalid port {port_str!r} in {s!r}") from exc

    # Path: legacy 2-segment OR path-style 2+ segment.
    raw_segments = raw_path.split("/")
    # Preserve trailing-empty info for "missing id" detection (`adapter/`).
    has_trailing_empty = raw_segments[-1] == "" and len(raw_segments) > 1
    path_parts = [p for p in raw_segments if p != ""]
    if len(path_parts) < 2 and not has_trailing_empty:
        raise ValueError(f"bad path in {s!r}: at least <type>/<id> required")

    if len(path_parts) == 0:
        raise ValueError(f"bad path in {s!r}: at least <type>/<id> required")

    type_ = path_parts[0]
    if type_ not in _VALID_TYPES:
        raise ValueError(
            f"unknown type {type_!r}; expected one of {sorted(_VALID_TYPES)}"
        )

    if type_ in _LEGACY_TYPES:
        # Legacy types stay strict: exactly 2 segments, id is the second.
        if len(path_parts) == 1 and has_trailing_empty:
            raise ValueError(f"missing id in {s!r}")
        if len(path_parts) != 2:
            raise ValueError(
                f"bad path in {s!r}: legacy type {type_!r} requires exactly "
                f"<type>/<id> (no slashes in id)"
            )
        id_ = path_parts[1]
    else:
        # Path-style types accept 2+ segments. id is the last segment.
        if len(path_parts) < 2:
            raise ValueError(f"missing id in {s!r}")
        id_ = path_parts[-1]

    if id_ == "":
        raise ValueError(f"missing id in {s!r}")

    params_dict: dict[str, str] = dict(parse_qsl(query, keep_blank_values=True))

    return EsrURI(
        org=org,
        host=host_str,
        port=port,
        type=type_,
        id=id_,
        segments=tuple(path_parts),
        params=MappingProxyType(params_dict),
    )


def build(
    type_: str,
    id_: str,
    *,
    host: str,
    port: int | None = None,
    org: str | None = None,
    params: dict[str, Any] | None = None,
) -> str:
    """Build a canonical 2-segment ``esr://`` URI string (legacy form)."""
    if type_ not in _VALID_TYPES:
        raise ValueError(f"unknown type {type_!r}")
    if host == "":
        raise ValueError("empty host")
    if id_ == "":
        raise ValueError("empty id")

    authority = host
    if port is not None:
        authority = f"{authority}:{port}"
    if org:
        authority = f"{org}@{authority}"

    s = f"esr://{authority}/{type_}/{id_}"

    if params:
        from urllib.parse import urlencode

        s = f"{s}?{urlencode(params)}"
    return s


def build_path(
    segments: list[str] | tuple[str, ...],
    *,
    host: str,
    port: int | None = None,
    org: str | None = None,
    params: dict[str, Any] | None = None,
) -> str:
    """Build a path-style ``esr://`` URI from path segments.

    The first segment must be a path-style type
    (e.g. ``adapters``, ``workspaces``, ``chats``, ``users``, ``sessions``).
    Use ``build`` for legacy 2-segment forms.
    """
    if len(segments) < 2:
        raise ValueError(
            f"path-style URI requires at least 2 segments; got {list(segments)!r}"
        )
    first = segments[0]
    if first not in _PATH_STYLE_TYPES:
        raise ValueError(
            f"first segment {first!r} is not a path-style type "
            f"(expected one of {sorted(_PATH_STYLE_TYPES)})"
        )
    if host == "":
        raise ValueError("empty host")
    for i, seg in enumerate(segments):
        if seg == "":
            raise ValueError(f"empty segment at index {i} in {list(segments)!r}")

    authority = host
    if port is not None:
        authority = f"{authority}:{port}"
    if org:
        authority = f"{org}@{authority}"

    s = f"esr://{authority}/" + "/".join(segments)

    if params:
        from urllib.parse import urlencode

        s = f"{s}?{urlencode(params)}"
    return s
