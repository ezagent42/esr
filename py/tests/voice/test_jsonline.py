"""Unit tests for _voice_common.jsonline — the stdin/stdout JSON-line
protocol helpers used by every voice sidecar.

Spec §8.1: requests `{"id": ..., "kind": "request", "payload": {...}}` in,
replies `{"id": ..., "kind": "reply", "payload": {...}}` out, streaming
flavour `{"id": ..., "kind": "stream_chunk", "payload": {...}}` +
`{"id": ..., "kind": "stream_end"}`.
"""
import io
import json

from _voice_common.jsonline import (
    read_requests,
    write_reply,
    write_stream_chunk,
    write_stream_end,
)


def test_read_requests_yields_parsed_objects() -> None:
    stdin = io.StringIO(
        '{"id":"r1","kind":"request","payload":{"text":"hi"}}\n'
        '{"id":"r2","kind":"request","payload":{}}\n'
    )
    out = list(read_requests(stdin))
    assert out == [
        {"id": "r1", "kind": "request", "payload": {"text": "hi"}},
        {"id": "r2", "kind": "request", "payload": {}},
    ]


def test_read_requests_skips_blank_and_bad_lines() -> None:
    stdin = io.StringIO(
        '\n'
        'not-json\n'
        '{"id":"r3","kind":"request","payload":{}}\n'
    )
    out = list(read_requests(stdin))
    assert out == [{"id": "r3", "kind": "request", "payload": {}}]


def test_write_reply_emits_single_json_line() -> None:
    buf = io.StringIO()
    write_reply(buf, "r1", {"text": "hello"})
    line = buf.getvalue()
    assert line.endswith("\n")
    parsed = json.loads(line)
    assert parsed == {"id": "r1", "kind": "reply", "payload": {"text": "hello"}}


def test_stream_chunk_and_end_are_distinct_kinds() -> None:
    buf = io.StringIO()
    write_stream_chunk(buf, "r1", {"bytes": "AAAA"})
    write_stream_end(buf, "r1")
    lines = [json.loads(line) for line in buf.getvalue().splitlines()]
    assert [f["kind"] for f in lines] == ["stream_chunk", "stream_end"]
    assert lines[0]["id"] == "r1" and lines[1]["id"] == "r1"
