"""PRD 03 F07 / F08 — handler worker dispatch + exception handling."""

from __future__ import annotations

import pytest
from pydantic import BaseModel

from esr.actions import Emit
from esr.handler import HANDLER_REGISTRY, STATE_REGISTRY, handler, handler_state
from esr.ipc.handler_worker import process_handler_call


@pytest.fixture(autouse=True)
def _clear_registries() -> None:
    HANDLER_REGISTRY.clear()
    STATE_REGISTRY.clear()


def _register_noop(actor_type: str = "noop") -> None:
    @handler_state(actor_type=actor_type, schema_version=1)
    class _S(BaseModel):
        model_config = {"frozen": True}
        counter: int = 0

    @handler(actor_type=actor_type, name="on_msg")
    def _on_msg(state: _S, event: object) -> tuple[_S, list[object]]:
        return _S(counter=state.counter + 1), [
            Emit(adapter="feishu", action="send", args={"x": state.counter})
        ]


# --- PRD 03 F07: handler_call → handler_reply --------------------------


def test_process_handler_call_returns_reply_payload() -> None:
    """Valid handler_call payload produces a handler_reply payload."""
    _register_noop()
    payload = {
        "handler": "noop.on_msg",
        "state": {"counter": 3},
        "event": {
            "source": "esr://localhost/adapter/feishu",
            "event_type": "msg_received",
            "args": {"chat_id": "oc_1"},
        },
    }
    reply = process_handler_call(payload)
    assert reply["new_state"] == {"counter": 4}
    assert reply["actions"] == [
        {"type": "emit", "adapter": "feishu", "action": "send", "args": {"x": 3}}
    ]
    assert "error" not in reply


def test_process_handler_call_unregistered_handler() -> None:
    """Unknown handler key surfaces as an error payload (not an exception)."""
    payload = {
        "handler": "nonexistent.on_msg",
        "state": {},
        "event": {"event_type": "e", "args": {}},
    }
    reply = process_handler_call(payload)
    assert reply["error"]["type"] == "HandlerNotRegistered"
    assert "nonexistent.on_msg" in reply["error"]["message"]


def test_process_handler_call_unregistered_state() -> None:
    """Handler registered but state model missing — return a specific error."""

    @handler(actor_type="orphan", name="on_msg")
    def _fn(state: object, event: object) -> tuple[object, list[object]]:
        return state, []

    payload = {
        "handler": "orphan.on_msg",
        "state": {},
        "event": {"event_type": "e", "args": {}},
    }
    reply = process_handler_call(payload)
    assert reply["error"]["type"] == "StateNotRegistered"


# --- PRD 03 F08: exception handling ------------------------------------


def test_process_handler_call_handler_exception() -> None:
    """Handler raising is caught → error payload, worker stays alive."""

    @handler_state(actor_type="boom", schema_version=1)
    class _S(BaseModel):
        model_config = {"frozen": True}

    @handler(actor_type="boom", name="on_msg")
    def _fn(state: _S, event: object) -> tuple[_S, list[object]]:
        raise RuntimeError("boom!")

    payload = {
        "handler": "boom.on_msg",
        "state": {},
        "event": {"event_type": "e", "args": {}},
    }
    reply = process_handler_call(payload)
    assert reply["error"]["type"] == "RuntimeError"
    assert reply["error"]["message"] == "boom!"


def test_process_handler_call_state_validation_error() -> None:
    """Invalid state dict surfaces via pydantic's ValidationError as error payload."""

    @handler_state(actor_type="strict", schema_version=1)
    class _S(BaseModel):
        model_config = {"frozen": True}
        required_field: int

    @handler(actor_type="strict", name="on_msg")
    def _fn(state: _S, event: object) -> tuple[_S, list[object]]:
        return state, []

    payload = {
        "handler": "strict.on_msg",
        "state": {},  # missing required_field
        "event": {"event_type": "e", "args": {}},
    }
    reply = process_handler_call(payload)
    assert "error" in reply
    assert reply["error"]["type"] == "ValidationError"


def test_process_handler_call_malformed_envelope_missing_handler_key() -> None:
    """Reviewer S3: contract is 'never raises' — missing keys must surface as error."""
    reply = process_handler_call({})
    assert "error" in reply
    assert reply["error"]["type"] == "MalformedEnvelope"


def test_process_handler_call_malformed_envelope_missing_event_type() -> None:
    """`event.event_type` is required; missing → MalformedEnvelope not KeyError."""
    _register_noop()

    payload = {
        "handler": "noop.on_msg",
        "state": {"counter": 0},
        "event": {"args": {}},  # no event_type
    }
    reply = process_handler_call(payload)
    assert "error" in reply
    assert reply["error"]["type"] == "MalformedEnvelope"
