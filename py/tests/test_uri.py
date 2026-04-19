"""PRD 02 F15 — esr:// URI parser (Python side)."""

from __future__ import annotations

import pytest

from esr.uri import EsrURI, build, parse


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
        params={},
    )
