"""esr:// URI parser + builder (PRD 02 F15, spec §7.5).

Canonical form::

    esr://[org@]host[:port]/<type>/<id>[?k=v&...]

``type`` is one of ``adapter``, ``actor``, ``command``. Empty host
is a hard error (paths like ``esr:///foo/bar`` are ill-formed — the
host is the anchor for cross-boundary routing).

The parser is intentionally strict: anything the spec doesn't allow
is rejected with ``ValueError``. This is the Python counterpart of
``Esr.URI`` in the Elixir runtime (PRD 01 F17) — the two must agree
on wire-level URI strings for IPC.
"""

from __future__ import annotations

from dataclasses import dataclass
from types import MappingProxyType
from typing import Any
from urllib.parse import parse_qsl

_VALID_TYPES = frozenset({"adapter", "actor", "command"})


@dataclass(frozen=True)
class EsrURI:
    """Parsed ``esr://`` URI (spec §7.5)."""

    org: str | None
    host: str
    port: int | None
    type: str
    id: str
    params: MappingProxyType[str, str]

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, EsrURI):
            return NotImplemented
        return (
            self.org == other.org
            and self.host == other.host
            and self.port == other.port
            and self.type == other.type
            and self.id == other.id
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

    path_parts = raw_path.split("/")
    if len(path_parts) < 2:
        raise ValueError(f"missing id in {s!r}")
    type_ = path_parts[0]
    id_ = "/".join(path_parts[1:])
    if type_ not in _VALID_TYPES:
        raise ValueError(f"unknown type {type_!r}; expected one of {sorted(_VALID_TYPES)}")
    if id_ == "":
        raise ValueError(f"missing id in {s!r}")

    params_dict: dict[str, str] = dict(parse_qsl(query, keep_blank_values=True))

    return EsrURI(
        org=org,
        host=host_str,
        port=port,
        type=type_,
        id=id_,
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
    """Build a canonical ``esr://`` URI string."""
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
