#!/bin/bash
# test-runner for adapter-cc-mcp
# Baseline: 7 passed in ~3.7s
# NOTE: cc_mcp is NOT registered in py/pyproject.toml's [tool.uv.sources].
# It requires pytest with transient deps provided via `uv run --with`.
# (Known build-config gap CC-MCP-1; tracked in bootstrap-report.md.)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)/adapters/cc_mcp"
PYTHONPATH=src exec uv run --with mcp --with anyio --with aiohttp --with websockets \
  --with pytest --with pytest-asyncio pytest tests/ "$@"
