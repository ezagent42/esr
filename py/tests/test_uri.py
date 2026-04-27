"""PRD 02 F15 — esr:// URI parser (Python side)."""

from __future__ import annotations

from types import MappingProxyType

import pytest

from esr.uri import (
    EsrURI,
    build,
    build_path,
    legacy_types,
    parse,
    path_style_types,
)


def test_parse_minimal() -> None:
    """Host + type + id, no org / port / params."""
    u = parse("esr://localhost/adapter/feishu-shared")
    assert u.host == "localhost"
    assert u.port is None
    assert u.org is None
    assert u.type == "adapter"
    assert u.id == "feishu-shared"
    assert u.params == {}


def test_parse_with_port() -> None:
    u = parse("esr://host.internal:4000/actor/feishu_thread.oc_1")
    assert u.host == "host.internal"
    assert u.port == 4000
    assert u.id == "feishu_thread.oc_1"


def test_parse_with_org_and_params() -> None:
    u = parse("esr://acme@host:4000/command/feishu-to-cc?thread_id=oc_1&mode=debug")
    assert u.org == "acme"
    assert u.host == "host"
    assert u.port == 4000
    assert u.type == "command"
    assert u.id == "feishu-to-cc"
    assert u.params == {"thread_id": "oc_1", "mode": "debug"}


def test_parse_adapter_type() -> None:
    u = parse("esr://localhost/adapter/feishu-shared")
    assert u.type == "adapter"


def test_parse_actor_type() -> None:
    u = parse("esr://localhost/actor/cc_session.cc-window-1")
    assert u.type == "actor"


def test_parse_command_type() -> None:
    u = parse("esr://localhost/command/feishu-to-cc")
    assert u.type == "command"


def test_parse_empty_host_raises() -> None:
    with pytest.raises(ValueError, match=r"empty host"):
        parse("esr:///adapter/feishu")


def test_parse_unknown_type_raises() -> None:
    with pytest.raises(ValueError, match=r"unknown type"):
        parse("esr://localhost/bogus/feishu")


def test_parse_wrong_scheme_raises() -> None:
    with pytest.raises(ValueError, match=r"expected esr:// scheme"):
        parse("https://localhost/adapter/feishu")


def test_parse_id_with_slash_raises() -> None:
    """Legacy types stay strict: 2-segment path only.

    Path-style RESTful types (e.g. ``adapters``, ``workspaces``,
    ``chats``) accept 3+ segments — see ``test_parse_path_style_*``
    below. Both sides (Elixir + Python) match.
    """
    with pytest.raises(ValueError, match=r"(slash|bad path|legacy type)"):
        parse("esr://localhost/actor/path/with/slashes")


def test_parse_missing_id_raises() -> None:
    with pytest.raises(ValueError, match=r"missing id"):
        parse("esr://localhost/adapter/")


def test_build_minimal() -> None:
    s = build("adapter", "feishu-shared", host="localhost")
    assert s == "esr://localhost/adapter/feishu-shared"


def test_build_with_org_and_port() -> None:
    s = build("actor", "feishu_thread.oc_1", host="host", port=4000, org="acme")
    assert s == "esr://acme@host:4000/actor/feishu_thread.oc_1"


def test_build_empty_host_raises() -> None:
    with pytest.raises(ValueError, match=r"empty host"):
        build("adapter", "x", host="")


def test_esr_uri_is_frozen() -> None:
    u = parse("esr://localhost/adapter/feishu")
    with pytest.raises(Exception):  # noqa: B017
        u.host = "other"  # type: ignore[misc]


def test_build_round_trip_through_parse() -> None:
    s = build("command", "feishu-to-cc", host="host", port=4000, org="acme")
    u = parse(s)
    assert u == EsrURI(
        org="acme",
        host="host",
        port=4000,
        type="command",
        id="feishu-to-cc",
        segments=("command", "feishu-to-cc"),
        params=MappingProxyType({}),
    )


# ---------------------------------------------------------------------------
# Path-style RESTful URIs (introduced 2026-04-27)
# ---------------------------------------------------------------------------


def test_parse_path_style_adapter() -> None:
    u = parse("esr://localhost/adapters/feishu/app_dev")
    assert u.host == "localhost"
    assert u.type == "adapters"
    assert u.id == "app_dev"
    assert u.segments == ("adapters", "feishu", "app_dev")


def test_parse_path_style_chat_under_workspace() -> None:
    u = parse("esr://localhost/workspaces/ws_dev/chats/oc_xxx")
    assert u.type == "workspaces"
    assert u.id == "oc_xxx"
    assert u.segments == ("workspaces", "ws_dev", "chats", "oc_xxx")


def test_parse_path_style_user() -> None:
    u = parse("esr://localhost/users/ou_abc")
    assert u.type == "users"
    assert u.id == "ou_abc"
    assert u.segments == ("users", "ou_abc")


def test_parse_path_style_session() -> None:
    u = parse("esr://localhost/sessions/sess_42")
    assert u.type == "sessions"
    assert u.id == "sess_42"
    assert u.segments == ("sessions", "sess_42")


def test_path_style_only_collection_segment_rejected() -> None:
    with pytest.raises(ValueError, match=r"bad path"):
        parse("esr://localhost/adapters")


def test_build_path_adapter() -> None:
    s = build_path(["adapters", "feishu", "app_dev"], host="localhost")
    assert s == "esr://localhost/adapters/feishu/app_dev"


def test_build_path_chat_under_workspace() -> None:
    s = build_path(
        ["workspaces", "ws_dev", "chats", "oc_xxx"], host="localhost"
    )
    assert s == "esr://localhost/workspaces/ws_dev/chats/oc_xxx"


def test_build_path_rejects_legacy_first_segment() -> None:
    with pytest.raises(ValueError, match=r"not a path-style type"):
        build_path(["actor", "x"], host="localhost")


def test_build_path_round_trip() -> None:
    s = build_path(["users", "ou_abc"], host="localhost")
    u = parse(s)
    assert u.segments == ("users", "ou_abc")


def test_legacy_types_set() -> None:
    assert "actor" in legacy_types()
    assert "adapter" in legacy_types()
    assert "adapters" not in legacy_types()


def test_path_style_types_set() -> None:
    assert "adapters" in path_style_types()
    assert "workspaces" in path_style_types()
    assert "chats" in path_style_types()
    assert "users" in path_style_types()
    assert "sessions" in path_style_types()
    assert "actor" not in path_style_types()
