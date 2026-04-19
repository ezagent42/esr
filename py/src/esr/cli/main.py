"""``esr`` CLI entry point (PRD 07)."""

from __future__ import annotations

import os
from pathlib import Path

import click
import yaml

# --- Context file helpers ----------------------------------------------


def _context_path() -> Path:
    return Path(os.path.expanduser("~")) / ".esr" / "context"


def _load_context() -> dict[str, str]:
    """Read ~/.esr/context; env ``ESR_CONTEXT`` takes precedence."""
    env = os.environ.get("ESR_CONTEXT")
    if env:
        return {"endpoint": _endpoint_from_host_port(env)}
    path = _context_path()
    if not path.exists():
        return {}
    data = yaml.safe_load(path.read_text()) or {}
    return dict(data)


def _save_context(host_port: str) -> None:
    """Persist the selected endpoint to ~/.esr/context."""
    path = _context_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        yaml.safe_dump({"endpoint": _endpoint_from_host_port(host_port)}),
        encoding="utf-8",
    )


def _endpoint_from_host_port(host_port: str) -> str:
    return f"ws://{host_port}/adapter_hub/socket"


def _host_port_from_endpoint(endpoint: str) -> str:
    prefix = "ws://"
    suffix = "/adapter_hub/socket"
    if endpoint.startswith(prefix):
        endpoint = endpoint[len(prefix):]
    if endpoint.endswith(suffix):
        endpoint = endpoint[: -len(suffix)]
    return endpoint


# --- CLI groups --------------------------------------------------------


@click.group()
def cli() -> None:
    """``esr`` — command-line entry to a running esrd."""


@cli.command("use")
@click.argument("host_port", required=False)
def use(host_port: str | None) -> None:
    """Set or print the target esrd endpoint (PRD 07 F01).

    With a ``host:port`` argument, persists ``~/.esr/context`` so future
    commands target that endpoint. Without arguments, prints the current
    endpoint (env ``ESR_CONTEXT`` overrides the file).
    """
    if host_port:
        _save_context(host_port)
        click.echo(f"set context: {host_port}")
        return

    ctx = _load_context()
    endpoint = ctx.get("endpoint")
    if not endpoint:
        click.echo(
            "no context set — run `esr use <host:port>` to select an esrd endpoint",
            err=True,
        )
        raise click.exceptions.Exit(code=1)
    click.echo(_host_port_from_endpoint(endpoint))
