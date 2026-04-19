"""PRD 04 F21 — cc_tmux output monitoring."""

from __future__ import annotations

from esr_cc_tmux.adapter import CcTmuxAdapter, parse_sentinel_line


def test_parse_sentinel_line_matches() -> None:
    """Lines beginning with `[esr-cc] ` yield a cc_output event dict."""
    line = "[esr-cc] {\"kind\": \"assistant\", \"text\": \"hello\"}"
    out = parse_sentinel_line("sess-A", line)
    assert out is not None
    assert out["event_type"] == "cc_output"
    assert out["args"]["session"] == "sess-A"
    assert out["args"]["text"] == "{\"kind\": \"assistant\", \"text\": \"hello\"}"


def test_parse_sentinel_line_ignores_non_sentinel() -> None:
    """Plain terminal noise doesn't produce an event."""
    for line in [
        "",
        "spam",
        "[esr-cc]",  # sentinel but no payload
        "prefixed [esr-cc] more",  # sentinel not at start
        "\x1b[1;32mcoloured output",
    ]:
        assert parse_sentinel_line("sess", line) is None, f"unexpected match: {line!r}"


def test_parse_sentinel_line_strips_trailing_newline() -> None:
    """Newline is stripped from the captured text."""
    out = parse_sentinel_line("s", "[esr-cc] hi\n")
    assert out is not None
    assert out["args"]["text"] == "hi"


def test_parse_sentinel_line_preserves_internal_whitespace() -> None:
    out = parse_sentinel_line("s", "[esr-cc]   multi   space   content")
    assert out is not None
    # The adapter takes everything after the sentinel verbatim so
    # downstream handlers can parse structured payloads (JSON, etc.)
    assert out["args"]["text"] == "  multi   space   content"


def test_adapter_exposes_parse_helper() -> None:
    """CcTmuxAdapter re-exports parse_sentinel_line for convenience."""
    assert hasattr(CcTmuxAdapter, "parse_line")
    assert callable(CcTmuxAdapter.parse_line)
