"""Exponential backoff schedule for IPC reconnects (shared)."""
from __future__ import annotations

#: Seconds between successive ``run_with_client`` attempts. Indexed by
#: attempt count with ``min(attempt, len-1)`` (the last entry is the
#: sustained ceiling).
RECONNECT_BACKOFF_SCHEDULE: tuple[float, ...] = (0.2, 0.4, 0.8, 1.6, 3.2, 5.0)
