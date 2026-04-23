"""K1 — tool schema descriptions must be adapter-agnostic (spec §13 item 4).

Runs as part of the adapters/cc_mcp test suite; fails the build if a
"Feishu" mention creeps back in.
"""
from __future__ import annotations

import re

from esr_cc_mcp.tools import list_tool_schemas


def test_no_feishu_in_tool_descriptions() -> None:
    tools = list_tool_schemas(role="diagnostic")
    pat = re.compile(r"feishu", re.IGNORECASE)
    offenders: list[str] = []
    for t in tools:
        if pat.search(t.description or ""):
            offenders.append(f"{t.name}.description: {t.description!r}")
        for prop_name, prop in (t.inputSchema.get("properties") or {}).items():
            desc = prop.get("description") or ""
            if pat.search(desc):
                offenders.append(f"{t.name}.{prop_name}.description: {desc!r}")
    assert offenders == [], "K1: sanitize these:\n  " + "\n  ".join(offenders)
