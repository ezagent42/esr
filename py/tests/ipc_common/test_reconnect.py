"""Smoke: RECONNECT_BACKOFF_SCHEDULE keeps its shape under the move."""
from _ipc_common.reconnect import RECONNECT_BACKOFF_SCHEDULE


def test_schedule_is_monotonic_capped_tuple_of_floats() -> None:
    assert isinstance(RECONNECT_BACKOFF_SCHEDULE, tuple)
    assert all(isinstance(x, float) for x in RECONNECT_BACKOFF_SCHEDULE)
    # Non-decreasing, bounded.
    assert list(RECONNECT_BACKOFF_SCHEDULE) == sorted(RECONNECT_BACKOFF_SCHEDULE)
    assert RECONNECT_BACKOFF_SCHEDULE[-1] <= 10.0
